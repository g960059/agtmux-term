import XCTest
import AppKit
@testable import AgtmuxTerm

final class GhosttyInputTests: XCTestCase {
    func testPackedScrollModsIncludesMomentumAndDirectPhaseBits() {
        let mods = GhosttyInput.packedScrollMods(
            precision: true,
            momentumPhase: .ended,
            phase: .changed
        )

        XCTAssertEqual(mods, 57)
    }

    func testPackedScrollModsUsesCancelledPrecedenceWhenPhaseContainsMultipleBits() {
        let mods = GhosttyInput.packedScrollMods(
            precision: false,
            momentumPhase: [.changed, .cancelled],
            phase: [.began, .ended]
        )

        XCTAssertEqual(mods, (5 << 1) | (4 << 4))
    }
}
