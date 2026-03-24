import XCTest
@testable import AgtmuxTerm

@MainActor
final class AppViewModelStartupDefaultsTests: XCTestCase {
    private let defaultsKey = "autoLaunchSessionName"
    private var savedValue: String?

    override func setUp() {
        super.setUp()
        savedValue = UserDefaults.standard.string(forKey: defaultsKey)
        UserDefaults.standard.removeObject(forKey: defaultsKey)
    }

    override func tearDown() {
        if let savedValue {
            UserDefaults.standard.set(savedValue, forKey: defaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: defaultsKey)
        }
        super.tearDown()
    }

    func testAutoLaunchDefaultsToDisabled() {
        let viewModel = AppViewModel()

        XCTAssertEqual(viewModel.autoLaunchSessionName, "")
    }

    func testAutoLaunchUsesStoredSessionNameWhenConfigured() {
        UserDefaults.standard.set("dev-shell", forKey: defaultsKey)

        let viewModel = AppViewModel()

        XCTAssertEqual(viewModel.autoLaunchSessionName, "dev-shell")
    }
}
