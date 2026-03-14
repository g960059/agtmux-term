import XCTest
import AppKit
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

        XCTAssertEqual(view.sentTexts, ["日本語"])
        XCTAssertEqual(view.sentPreedits.first ?? nil, "にほんご")
        XCTAssertEqual(view.sentPreedits.last ?? "not-nil", nil)
        XCTAssertTrue(view.sentRawKeys.isEmpty)
    }

    func testInsertTextClearsPreeditWhenMarkedTextEnds() {
        let view = GhosttyTerminalViewSpy()

        view.setMarkedText("にほんご", selectedRange: NSRange(location: 0, length: 4), replacementRange: NSRange(location: NSNotFound, length: 0))
        view.insertText("日本語", replacementRange: NSRange(location: NSNotFound, length: 0))

        XCTAssertEqual(view.sentPreedits, ["にほんご", nil])
        XCTAssertEqual(view.sentTexts, ["日本語"])
    }

    private func makeKeyDownEvent(characters: String, keyCode: UInt16) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
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
        interpretation?()
    }

    override func sendKeyToSurface(event: NSEvent, text: String?, composing: Bool) -> Bool {
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
