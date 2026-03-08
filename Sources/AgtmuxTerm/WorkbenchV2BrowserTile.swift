import SwiftUI
import WebKit
import AppKit
import AgtmuxTermCore

struct WorkbenchBrowserTileViewV2: View {
    let tile: WorkbenchTile
    let url: URL
    let sourceContext: String?
    let isFocused: Bool

    @Environment(WorkbenchStoreV2.self) private var store
    @State private var loadError: String?

    var body: some View {
        ZStack(alignment: .topLeading) {
            browserSurface

            VStack(alignment: .leading, spacing: 12) {
                header
                Spacer(minLength: 0)
                if let loadError, !loadError.isEmpty {
                    errorBanner(loadError)
                }
            }
            .padding(16)
        }
        .overlay(tileBorder)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(8)
        .contentShape(Rectangle())
        .onTapGesture {
            store.focusTile(id: tile.id)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.workspaceTilePrefix + tile.id.uuidString)
        .accessibilityLabel(tile.kind.displayTitle)
        .accessibilityValue(loadError ?? "Browser tile")
    }

    private var browserSurface: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.08),
                            Color.white.opacity(0.02)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            WorkbenchBrowserWebView(tileID: tile.id, url: url, loadError: $loadError)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "globe")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.88))

            VStack(alignment: .leading, spacing: 3) {
                Text(url.host ?? tile.kind.displayTitle)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.94))
                    .lineLimit(1)

                Text(sourceContext ?? url.absoluteString)
                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.68))
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            Button {
                NSWorkspace.shared.open(url)
            } label: {
                Image(systemName: "arrow.up.forward.square")
                    .font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.white.opacity(0.76))
            .help("Open in default browser")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.black.opacity(0.30), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11, weight: .bold))
            Text(message)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .lineLimit(3)
        }
        .foregroundStyle(Color.white.opacity(0.90))
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.red.opacity(0.34), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var tileBorder: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .stroke(
                isFocused ? Color.white.opacity(0.18) : Color.white.opacity(0.10),
                lineWidth: 1
            )
    }
}

struct WorkbenchBrowserWebView: NSViewRepresentable {
    let tileID: UUID
    let url: URL
    @Binding var loadError: String?

    func makeCoordinator() -> Coordinator {
        Coordinator(loadError: $loadError)
    }

    func makeNSView(context: Context) -> WKWebView {
        let webView = WKWebView(frame: .zero)
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")
        context.coordinator.load(tileID: tileID, url: url, in: webView)
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        guard context.coordinator.shouldLoad(url: url, tileID: tileID) else { return }
        context.coordinator.load(tileID: tileID, url: url, in: nsView)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        enum NavigationResolution {
            case current
            case tracked(UUID)
            case unknown
        }

        @Binding private var loadError: String?
        var lastLoadedURL: URL?
        var lastLoadedTileID: UUID?
        private var currentLoadToken: UUID?
        private var navigationTokens: [ObjectIdentifier: UUID] = [:]

        init(loadError: Binding<String?>) {
            self._loadError = loadError
        }

        func shouldLoad(url: URL, tileID: UUID) -> Bool {
            lastLoadedURL != url || lastLoadedTileID != tileID
        }

        @discardableResult
        func beginLoad(tileID: UUID, url: URL) -> UUID {
            loadError = nil
            lastLoadedURL = url
            lastLoadedTileID = tileID
            let token = UUID()
            currentLoadToken = token
            return token
        }

        func load(tileID: UUID, url: URL, in webView: WKWebView) {
            let token = beginLoad(tileID: tileID, url: url)
            navigationTokens.removeAll(keepingCapacity: true)
            if let navigation = webView.load(URLRequest(url: url)) {
                navigationTokens[ObjectIdentifier(navigation)] = token
            }
        }

        func finishLoad(_ resolution: NavigationResolution) {
            guard shouldCommit(resolution) else { return }
            loadError = nil
        }

        func failLoad(
            _ resolution: NavigationResolution,
            error: Error
        ) {
            guard shouldCommit(resolution) else { return }
            guard !Self.isNavigationCancellation(error) else { return }
            loadError = error.localizedDescription
        }

        private func shouldCommit(_ resolution: NavigationResolution) -> Bool {
            switch resolution {
            case .current:
                return true
            case .tracked(let token):
                return token == currentLoadToken
            case .unknown:
                return false
            }
        }

        private func resolveNavigation(_ navigation: WKNavigation?) -> NavigationResolution {
            guard let navigation else {
                return .current
            }
            guard let token = navigationTokens.removeValue(forKey: ObjectIdentifier(navigation)) else {
                return .unknown
            }
            return .tracked(token)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            finishLoad(resolveNavigation(navigation))
        }

        func webView(
            _ webView: WKWebView,
            didFail navigation: WKNavigation!,
            withError error: Error
        ) {
            failLoad(resolveNavigation(navigation), error: error)
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: Error
        ) {
            failLoad(resolveNavigation(navigation), error: error)
        }

        static func isNavigationCancellation(_ error: Error) -> Bool {
            let nsError = error as NSError
            return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
        }
    }
}
