import XCTest
@testable import AgtmuxTerm

final class TerminalHostModeTests: XCTestCase {
    func testDefaultsToLegacyWhenEnvironmentIsMissingOrUnknown() {
        XCTAssertEqual(TerminalHostMode(environment: [:]), .legacy)
        XCTAssertEqual(TerminalHostMode(environment: [TerminalHostMode.environmentKey: "bogus"]), .legacy)
    }

    func testParsesNextHostModeSynonyms() {
        XCTAssertEqual(TerminalHostMode(environment: [TerminalHostMode.environmentKey: "next"]), .next)
        XCTAssertEqual(TerminalHostMode(environment: [TerminalHostMode.environmentKey: "native"]), .next)
        XCTAssertEqual(TerminalHostMode(environment: [TerminalHostMode.environmentKey: "renderer-owned"]), .next)
    }

    func testHostViewIdentityIncludesMode() {
        let surfaceID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        XCTAssertNotEqual(
            TerminalHostContainer.hostViewIdentity(surfaceID: surfaceID, mode: .legacy),
            TerminalHostContainer.hostViewIdentity(surfaceID: surfaceID, mode: .next)
        )
    }
}
