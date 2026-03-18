import XCTest
import AppKit
import GhosttyKit
@testable import AgtmuxTerm

@MainActor
final class GhosttyTerminalViewIMETests: XCTestCase {
    func testMarkedTextEnterCommitPrefersIMEOverRawReturn() {
        let view = GhosttyTerminalViewSpy()
        view.sendKeyResult = true
        view.interpretation = {
            view.insertText("日本語", replacementRange: NSRange(location: NSNotFound, length: 0))
        }

        view.setMarkedText("にほんご", selectedRange: NSRange(location: 0, length: 4), replacementRange: NSRange(location: NSNotFound, length: 0))
        view.keyDown(with: makeKeyDownEvent(characters: "\r", keyCode: 0x24))

        XCTAssertTrue(view.sentTexts.isEmpty)
        XCTAssertEqual(view.sentPreedits.first ?? nil, "にほんご")
        XCTAssertEqual(view.sentPreedits.last ?? "not-nil", nil)
        XCTAssertEqual(view.sentRawKeys.map(\.characters), ["日本語"])
    }

    func testInsertTextClearsPreeditWhenMarkedTextEnds() {
        let view = GhosttyTerminalViewSpy()

        view.setMarkedText("にほんご", selectedRange: NSRange(location: 0, length: 4), replacementRange: NSRange(location: NSNotFound, length: 0))
        view.insertText("日本語", replacementRange: NSRange(location: NSNotFound, length: 0))

        XCTAssertEqual(view.sentPreedits, ["にほんご", nil])
        XCTAssertEqual(view.sentTexts, ["日本語"])
    }

    func testControlModifiedLetterUsesPrintableGhosttyText() {
        let view = GhosttyTerminalViewSpy()
        view.sendKeyResult = true

        view.keyDown(with: makeKeyDownEvent(characters: "\u{1}", keyCode: 0x00, modifierFlags: [.control]))

        XCTAssertEqual(view.sentRawKeys.count, 1)
        XCTAssertEqual(view.sentRawKeys.first?.characters, "a")
        XCTAssertEqual(view.sentRawKeys.first?.composing, false)
    }

    func testFlagsChangedEventConvertsWithoutRepeatQueryCrash() {
        let event = NSEvent.keyEvent(
            with: .flagsChanged,
            location: .zero,
            modifierFlags: [.control],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: 0x3B
        )!

        let key = GhosttyInput.toGhosttyKey(event)

        XCTAssertEqual(key.action, GHOSTTY_ACTION_PRESS)
        XCTAssertEqual(key.keycode, 0x3B)
        XCTAssertEqual(key.mods.rawValue & GHOSTTY_MODS_CTRL.rawValue, GHOSTTY_MODS_CTRL.rawValue)
    }

    func testKeyDownTextAccumulatorReplaysAsRawKeyEventInsteadOfPaste() {
        let view = GhosttyTerminalViewSpy()
        view.sendKeyResult = true

        view.keyDown(with: makeKeyDownEvent(characters: "o", keyCode: 0x1F))

        XCTAssertTrue(view.sentTexts.isEmpty)
        XCTAssertEqual(view.sentRawKeys.count, 1)
        XCTAssertEqual(view.sentRawKeys.first?.characters, "o")
    }

    func testTmuxNextPanePerfSeamSendsPrefixThenNextPaneKey() {
        let view = GhosttyTerminalViewSpy()
        view.sendKeyResult = true

        let sent = view.sendTmuxNextPaneKeysForTesting(windowNumber: 0)

        XCTAssertTrue(sent)
        XCTAssertEqual(view.sentRawKeys.count, 2)
        XCTAssertEqual(view.sentRawKeys.first?.characters, "a")
        XCTAssertEqual(view.sentRawKeys.last?.characters, "o")
        XCTAssertTrue(view.sentTexts.isEmpty)
    }

    func testMouseDownClaimsFirstResponderBeforeSurfaceInput() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let root = NSView(frame: window.contentView?.bounds ?? .zero)
        let view = GhosttyTerminalViewSpy(frame: NSRect(x: 0, y: 0, width: 320, height: 240))
        root.addSubview(view)
        window.contentView = root

        let event = makeMouseDownEvent(windowNumber: window.windowNumber)
        view.mouseDown(with: event)

        XCTAssertTrue(window.firstResponder === view)
    }

    private func makeKeyDownEvent(
        characters: String,
        keyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags = []
    ) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifierFlags,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        )!
    }

    private func makeMouseDownEvent(windowNumber: Int) -> NSEvent {
        NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: NSPoint(x: 10, y: 10),
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1.0
        )!
    }
}

@MainActor
private final class GhosttyTerminalViewSpy: GhosttyTerminalView {
    var sentPreedits: [String?] = []
    var sentTexts: [String] = []
    var sentRawKeys: [(characters: String?, composing: Bool)] = []
    var sendKeyResult = false
    var interpretation: (() -> Void)?
    private var currentMarkedText = ""

    override func interpretKeyEvents(_ eventArray: [NSEvent]) {
        if let interpretation {
            interpretation()
            return
        }

        for event in eventArray {
            if event.modifierFlags.contains(.control) {
                continue
            }

            guard let characters = event.characters, characters.isEmpty == false else {
                continue
            }

            insertText(characters, replacementRange: NSRange(location: NSNotFound, length: 0))
        }
    }

    override func sendKeyToSurface(
        event: NSEvent,
        translationMods: NSEvent.ModifierFlags? = nil,
        text: String?,
        composing: Bool
    ) -> Bool {
        sentRawKeys.append((characters: text ?? event.characters, composing: composing))
        return sendKeyResult
    }

    override func sendTextToSurface(_ text: String) {
        sentTexts.append(text)
    }

    override func syncPreeditToSurface(clearIfNeeded: Bool = true) {
        if currentMarkedText.isEmpty == false {
            sentPreedits.append(currentMarkedText)
        } else if clearIfNeeded {
            sentPreedits.append(nil)
        }
    }

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        switch string {
        case let attributed as NSAttributedString:
            currentMarkedText = attributed.string
        case let plain as String:
            currentMarkedText = plain
        default:
            currentMarkedText = ""
        }
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
    }

    override func unmarkText() {
        currentMarkedText = ""
        super.unmarkText()
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        currentMarkedText = ""
        super.insertText(string, replacementRange: replacementRange)
    }
}
