import XCTest
import SwiftUI
import WebKit
@testable import AgtmuxTerm

@MainActor
final class WorkbenchV2BrowserTileTests: XCTestCase {
    func testCoordinatorReloadsWhenTileIdentityChangesForSameURL() {
        let url = URL(string: "https://example.com/docs")!
        let coordinator = WorkbenchBrowserWebView.Coordinator(loadError: LoadErrorBox().binding)
        coordinator.lastLoadedURL = url
        coordinator.lastLoadedTileID = UUID()

        XCTAssertTrue(coordinator.shouldLoad(url: url, tileID: UUID()))
    }

    func testCoordinatorSkipsReloadWhenURLAndTileIdentityMatch() {
        let url = URL(string: "https://example.com/docs")!
        let tileID = UUID()
        let coordinator = WorkbenchBrowserWebView.Coordinator(loadError: LoadErrorBox().binding)
        coordinator.lastLoadedURL = url
        coordinator.lastLoadedTileID = tileID

        XCTAssertFalse(coordinator.shouldLoad(url: url, tileID: tileID))
    }

    func testCoordinatorKeepsExplicitNavigationFailureVisible() {
        let loadError = LoadErrorBox()
        let coordinator = WorkbenchBrowserWebView.Coordinator(loadError: loadError.binding)

        coordinator.webView(
            WKWebView(frame: .zero),
            didFailProvisionalNavigation: nil,
            withError: NSError(
                domain: NSURLErrorDomain,
                code: NSURLErrorCannotFindHost,
                userInfo: [NSLocalizedDescriptionKey: "Cannot find host"]
            )
        )

        XCTAssertEqual(loadError.value, "Cannot find host")
    }

    func testCoordinatorIgnoresCancelledNavigationFailures() {
        let loadError = LoadErrorBox(value: "Existing error")
        let coordinator = WorkbenchBrowserWebView.Coordinator(loadError: loadError.binding)

        coordinator.webView(
            WKWebView(frame: .zero),
            didFail: nil,
            withError: NSError(
                domain: NSURLErrorDomain,
                code: NSURLErrorCancelled,
                userInfo: [NSLocalizedDescriptionKey: "cancelled"]
            )
        )

        XCTAssertEqual(loadError.value, "Existing error")
    }

    func testCoordinatorClearsErrorAfterSuccessfulLoad() {
        let loadError = LoadErrorBox(value: "Previous failure")
        let coordinator = WorkbenchBrowserWebView.Coordinator(loadError: loadError.binding)

        coordinator.finishLoad(.current)

        XCTAssertNil(loadError.value)
    }

    func testCoordinatorIgnoresFailureFromStaleLoadToken() {
        let loadError = LoadErrorBox()
        let coordinator = WorkbenchBrowserWebView.Coordinator(loadError: loadError.binding)

        let staleToken = coordinator.beginLoad(
            tileID: UUID(),
            url: URL(string: "https://example.com/old")!
        )
        _ = coordinator.beginLoad(
            tileID: UUID(),
            url: URL(string: "https://example.com/new")!
        )

        coordinator.failLoad(
            .tracked(staleToken),
            error: NSError(
                domain: NSURLErrorDomain,
                code: NSURLErrorCannotFindHost,
                userInfo: [NSLocalizedDescriptionKey: "Cannot find host"]
            )
        )

        XCTAssertNil(loadError.value)
    }

    func testCoordinatorIgnoresSuccessFromStaleLoadToken() {
        let loadError = LoadErrorBox()
        let coordinator = WorkbenchBrowserWebView.Coordinator(loadError: loadError.binding)

        let staleToken = coordinator.beginLoad(
            tileID: UUID(),
            url: URL(string: "https://example.com/old")!
        )
        let currentToken = coordinator.beginLoad(
            tileID: UUID(),
            url: URL(string: "https://example.com/new")!
        )

        coordinator.failLoad(
            .tracked(currentToken),
            error: NSError(
                domain: NSURLErrorDomain,
                code: NSURLErrorCannotFindHost,
                userInfo: [NSLocalizedDescriptionKey: "Current failure"]
            )
        )
        coordinator.finishLoad(.tracked(staleToken))

        XCTAssertEqual(loadError.value, "Current failure")
    }
}

@MainActor
private final class LoadErrorBox {
    var value: String?

    init(value: String? = nil) {
        self.value = value
    }

    var binding: Binding<String?> {
        Binding(
            get: { self.value },
            set: { self.value = $0 }
        )
    }
}
