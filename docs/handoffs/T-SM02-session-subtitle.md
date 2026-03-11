# Handoff: T-SM02 — Session Metadata Display (2-line row + UX improvements)

**Task**: Improve sidebar session display:
1. Remove provider name ("claude"/"codex") as title fallback — show working dir instead
2. Always show `updatedAt` for managed panes (not just idle/waiting/error)
3. Add 2-line row with `session_subtitle` when available

**Depends on**: T-SM01 is merged → daemon now sends `session_subtitle` in JSON.

---

## Context: User Feedback

Currently, when there's no `conversationTitle`, the sidebar shows "claude" or "codex" as the title. But the provider icon already communicates this. The user wants:
- Useful fallback title that helps identify *which* session (e.g., working directory)
- `updatedAt` always visible (not hidden while running)
- Subtitle showing session summary/firstPrompt

---

## Change 1 — Title Fallback: Remove Provider Name

**File**: `Sources/AgtmuxTermCore/CoreModels.swift`

Current `primaryLabel`:
```swift
package var primaryLabel: String {
    if isManaged {
        return conversationTitle ?? provider?.rawValue ?? paneId
    } else {
        return currentCmd ?? paneId
    }
}
```

Change to — replace provider fallback with last path component:
```swift
package var primaryLabel: String {
    if isManaged {
        if let title = conversationTitle, !title.isEmpty {
            return title
        }
        // Fall back to working directory name (more useful than provider name,
        // which is already shown by the provider icon)
        if let path = currentPath, !path.isEmpty {
            let url = URL(fileURLWithPath: path)
            let folderName = url.lastPathComponent
            if !folderName.isEmpty && folderName != "/" {
                return folderName
            }
        }
        return paneId
    } else {
        return currentCmd ?? paneId
    }
}
```

**Note**: The comment in `CoreModels.swift` above `primaryLabel` mentions the old behavior — update it to reflect the new fallback chain.

---

## Change 2 — Always Show updatedAt for Managed Panes

**File**: `Sources/AgtmuxTermCore/PaneDisplayCompatFallback.swift`

Current `freshnessText(ageSecs:activityState:)`:
```swift
package static func freshnessText(ageSecs: Int?, activityState: ActivityState) -> String? {
    guard activityState != .running, let ageSecs else { return nil }
    // ...
}
```

Remove the `activityState != .running` guard — always show for managed panes:
```swift
package static func freshnessText(ageSecs: Int?, activityState: ActivityState) -> String? {
    guard let ageSecs else { return nil }
    switch ageSecs {
    case 0..<60:
        return "\(ageSecs)s"
    case 60..<3600:
        return "\(ageSecs / 60)m"
    default:
        return "\(ageSecs / 3600)h"
    }
}
```

Also update `PaneDisplayState.freshnessText(ageSecs:pane:presentation:)` in `PaneDisplayState.swift`:
```swift
private static func freshnessText(
    ageSecs: Int?,
    pane: AgtmuxPane,
    presentation: PanePresentationState
) -> String? {
    // Always show freshness for managed panes — user needs to know when session was last active
    return PaneDisplayCompatFallback.freshnessText(ageSecs: ageSecs, activityState: pane.activityState)
}
```
(Remove the `presentation.primaryState == .running { return nil }` guard.)

---

## Change 3 — Add sessionSubtitle to AgtmuxPane

**File**: `Sources/AgtmuxTermCore/CoreModels.swift`

Add field:
```swift
package let sessionSubtitle: String?   // subtitle/summary, differs from conversationTitle
```

Add to memberwise `init`:
```swift
sessionSubtitle: String? = nil,
```

Add to body:
```swift
self.sessionSubtitle = sessionSubtitle
```

**RawPane DTO** (wherever raw JSON decoding happens — search for `conversationTitle` in the decoder):
```swift
let sessionSubtitle: String?

// In CodingKeys:
case sessionSubtitle = "session_subtitle"
```

**All factory methods** that create `AgtmuxPane` (search for `conversationTitle:` call sites):
- Pass `sessionSubtitle: raw.sessionSubtitle` through

---

## Change 4 — 2-line Sidebar Row

**File**: `Sources/AgtmuxTerm/AppViewModel.swift`

Add helper method:
```swift
func paneDisplaySubtitle(for pane: AgtmuxPane) -> String? {
    guard pane.presence == .managed else { return nil }
    return pane.sessionSubtitle
}
```

**File**: `Sources/AgtmuxTerm/SidebarView.swift`

In `PaneRowView.body`, replace the single `Text(viewModel.paneDisplayTitle(for: pane))` with:
```swift
VStack(alignment: .leading, spacing: 1) {
    Text(viewModel.paneDisplayTitle(for: pane))
        .font(.system(size: 13, weight: isSelected ? .semibold : .regular, design: .rounded))
        .lineLimit(1)
        .truncationMode(.tail)
        .foregroundStyle(isManaged ? Color.white.opacity(0.95) : Color.white.opacity(0.82))
    if isManaged, let subtitle = viewModel.paneDisplaySubtitle(for: pane) {
        Text(subtitle)
            .font(.system(size: 11, design: .rounded))
            .lineLimit(1)
            .truncationMode(.tail)
            .foregroundStyle(Color.white.opacity(0.45))
    }
}
```

**Row height**: Use fixed minimum height for managed panes to prevent layout jumping:
```swift
.padding(.horizontal, 10)
.padding(.vertical, isManaged ? 4 : 6)
.padding(.leading, 10)
.frame(minHeight: isManaged ? 44 : 30, maxWidth: .infinity, alignment: .leading)
```

---

## Acceptance Criteria

1. `swift build` PASS
2. `swift test` PASS (deterministic tests)
3. Managed pane with no title shows working directory name (e.g. "agtmux") instead of "claude"/"codex"
4. `updatedAt` (freshness text) is always visible for managed panes — including while running
5. Managed pane with `session_subtitle` shows 2-line row; without shows single-line (no empty gap)
6. Unmanaged pane always shows single-line row

---

## Commit Message

```
feat: session metadata display — dir fallback, always-visible age, 2-line subtitle (T-SM02)
```
