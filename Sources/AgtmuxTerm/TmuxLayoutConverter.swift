import Foundation

// MARK: - TmuxLayoutConverter

/// Parses a tmux `window_layout` string into a `LayoutNode` BSP tree.
///
/// **Layout string format** (tmux 3.x, from `#{window_layout}` or `%layout-change`):
///   ```
///   <5-char-checksum>,<tree>
///   ```
///   where `<tree>` is one of:
///   - Leaf:    `<W>x<H>,<x>,<y>,<pane_index>`
///   - H-split: `<W>x<H>,<x>,<y>{<child>,<child>,...}`  (left | right, `{...}`)
///   - V-split: `<W>x<H>,<x>,<y>[<child>,<child>,...]`  (top / bottom, `[...]`)
///
/// `<pane_index>` in leaf nodes is the bare integer from the pane ID.
/// For example, pane `%250` has index `250`.
///
/// Multiple children (>2) are folded right into a chain of binary `SplitContainer`s.
/// Ratios are derived from character-cell dimensions — no pixel conversion is needed
/// because `SplitContainer.ratio` is dimensionless (firstChild / total).
struct TmuxLayoutConverter {

    // MARK: - Intermediate AST

    private indirect enum TmuxNode {
        case leaf(paneNum: Int, w: Int, h: Int)
        case hsplit(children: [TmuxNode], w: Int, h: Int)  // { } — left | right
        case vsplit(children: [TmuxNode], w: Int, h: Int)  // [ ] — top / bottom

        var charWidth:  Int {
            switch self {
            case .leaf(_, let w, _):    return w
            case .hsplit(_, let w, _):  return w
            case .vsplit(_, let w, _):  return w
            }
        }
        var charHeight: Int {
            switch self {
            case .leaf(_, _, let h):    return h
            case .hsplit(_, _, let h):  return h
            case .vsplit(_, _, let h):  return h
            }
        }
    }

    // MARK: - Public

    /// Convert a tmux `window_layout` string to a `LayoutNode` BSP.
    ///
    /// - Parameters:
    ///   - layoutString: Full layout string including the 5-char checksum prefix,
    ///                   e.g. `"c1e7,220x50,0,0{110x50,0,0,1,109x50,111,0,2}"`.
    ///   - windowPanes:  All `AgtmuxPane` objects in the window (provides metadata
    ///                   such as `sessionName` and `source` for each leaf).
    ///   - source:       `"local"` or SSH hostname applied to every created `LeafPane`.
    /// - Returns: `LayoutNode`, or `nil` if the layout string cannot be parsed or
    ///            if a pane index in the string is not found in `windowPanes`.
    static func convert(layoutString: String,
                        windowPanes: [AgtmuxPane],
                        source: String) -> LayoutNode? {
        // Strip the 5-char checksum + comma (e.g. "c1e7a,")
        guard let commaIdx = layoutString.firstIndex(of: ",") else { return nil }
        let treeStr = layoutString[layoutString.index(after: commaIdx)...]

        guard let (node, _) = parseNode(treeStr) else { return nil }

        // Build pane-number → AgtmuxPane lookup.
        // pane.paneId is "%250" → key = 250.
        var panesByNum: [Int: AgtmuxPane] = [:]
        for pane in windowPanes {
            let id = pane.paneId
            if id.hasPrefix("%"), let num = Int(id.dropFirst()) {
                panesByNum[num] = pane
            }
        }

        return toLayoutNode(node, panesByNum: panesByNum, source: source)
    }

    // MARK: - Parser

    /// Parse one `TmuxNode` from the start of `s`.
    /// Returns `(node, remainder)` where `remainder` is the unconsumed suffix.
    private static func parseNode(_ s: Substring) -> (TmuxNode, Substring)? {
        var rest = s

        // Parse width (digits before 'x')
        guard let xIdx = rest.firstIndex(of: "x"),
              let w = Int(rest[..<xIdx]) else { return nil }
        rest = rest[rest.index(after: xIdx)...]

        // Parse height (digits before first ',')
        guard let c1 = rest.firstIndex(of: ","),
              let h = Int(rest[..<c1]) else { return nil }
        rest = rest[rest.index(after: c1)...]

        // Skip x-coordinate (up to next ',')
        guard let c2 = rest.firstIndex(of: ",") else { return nil }
        rest = rest[rest.index(after: c2)...]

        // Read y-coordinate up to next ',', '[', or '{'
        let yEnd = rest.firstIndex(where: { $0 == "," || $0 == "[" || $0 == "{" })
                   ?? rest.endIndex
        rest = rest[yEnd...]

        guard !rest.isEmpty else { return nil }

        switch rest.first! {
        case "[", "{":
            let isVertical = rest.first! == "["
            rest = rest[rest.index(after: rest.startIndex)...]  // consume '[' or '{'
            let closeBracket: Character = isVertical ? "]" : "}"

            // Parse comma-separated children at this nesting level.
            // Recursive calls consume exactly one child and its sub-tree each time.
            var children: [TmuxNode] = []
            while !rest.isEmpty && rest.first != closeBracket {
                guard let (child, after) = parseNode(rest) else { return nil }
                children.append(child)
                rest = after
                if rest.first == "," {
                    rest = rest[rest.index(after: rest.startIndex)...]
                }
            }
            if rest.first == closeBracket {
                rest = rest[rest.index(after: rest.startIndex)...]
            }

            if isVertical {
                return (.vsplit(children: children, w: w, h: h), rest)
            } else {
                return (.hsplit(children: children, w: w, h: h), rest)
            }

        case ",":
            rest = rest[rest.index(after: rest.startIndex)...]  // consume ','
            // Parse pane number (run of digits)
            let numEnd = rest.firstIndex(where: { !$0.isNumber }) ?? rest.endIndex
            guard let paneNum = Int(rest[..<numEnd]) else { return nil }
            rest = rest[numEnd...]
            return (.leaf(paneNum: paneNum, w: w, h: h), rest)

        default:
            return nil
        }
    }

    // MARK: - BSP conversion

    private static func toLayoutNode(_ node: TmuxNode,
                                     panesByNum: [Int: AgtmuxPane],
                                     source: String) -> LayoutNode? {
        switch node {
        case .leaf(let paneNum, _, _):
            guard let pane = panesByNum[paneNum] else { return nil }
            let leaf = LeafPane(tmuxPaneID:  pane.paneId,
                                sessionName: pane.sessionName,
                                source:      source,
                                linkedSession: .creating)
            return .leaf(leaf)

        case .hsplit(let children, let totalW, _):
            return binaryFold(children,
                              totalChars: totalW,
                              axis: .horizontal,
                              panesByNum: panesByNum,
                              source: source)

        case .vsplit(let children, _, let totalH):
            return binaryFold(children,
                              totalChars: totalH,
                              axis: .vertical,
                              panesByNum: panesByNum,
                              source: source)
        }
    }

    /// Fold a list of children right into a chain of binary `SplitContainer`s.
    ///
    /// `{A, B, C}` → `split(.h, A, split(.h, B, C))` (right-associative).
    /// The first child's character dimension divided by the total gives the ratio.
    private static func binaryFold(_ children: [TmuxNode],
                                   totalChars: Int,
                                   axis: SplitAxis,
                                   panesByNum: [Int: AgtmuxPane],
                                   source: String) -> LayoutNode? {
        guard !children.isEmpty else { return nil }
        if children.count == 1 {
            return toLayoutNode(children[0], panesByNum: panesByNum, source: source)
        }

        let firstChars = axis == .horizontal
            ? children[0].charWidth
            : children[0].charHeight

        let ratio = totalChars > 0
            ? CGFloat(firstChars) / CGFloat(totalChars)
            : 0.5

        guard let first = toLayoutNode(children[0], panesByNum: panesByNum, source: source)
        else { return nil }

        // Remaining children share `totalChars - firstChars - 1` (divider column/row).
        let remainingTotal = max(1, totalChars - firstChars - 1)
        guard let second = binaryFold(Array(children.dropFirst()),
                                      totalChars: remainingTotal,
                                      axis: axis,
                                      panesByNum: panesByNum,
                                      source: source)
        else { return nil }

        let container = SplitContainer(axis: axis,
                                       ratio: max(0.1, min(0.9, ratio)),
                                       first: first,
                                       second: second)
        return .split(container)
    }
}
