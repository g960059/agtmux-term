import Observation
import SwiftUI
import AgtmuxTermCore

struct WorkbenchV2DocumentLoadToken: Hashable {
    let tileID: UUID
    let ref: DocumentRef
    let attempt: Int

    init(tileID: UUID, ref: DocumentRef, attempt: Int = 0) {
        self.tileID = tileID
        self.ref = ref
        self.attempt = attempt
    }
}

struct WorkbenchV2DocumentLoadRequest: Hashable {
    let token: WorkbenchV2DocumentLoadToken
    let offlineHostnames: Set<String>
    let inventoryReady: Bool

    func shouldDeferLoad(hostsConfig: HostsConfig) -> Bool {
        guard case .remote(let hostKey) = token.ref.target else {
            return false
        }
        return !inventoryReady && hostsConfig.host(id: hostKey) != nil
    }
}

enum WorkbenchV2DocumentRestoreIssue: Equatable {
    case hostMissing(String)
    case hostOffline(String)
    case pathMissing(String)
    case accessFailed(String)

    var title: String {
        switch self {
        case .hostMissing:
            return "Host missing"
        case .hostOffline:
            return "Host offline"
        case .pathMissing:
            return "Path missing"
        case .accessFailed:
            return "Access failed"
        }
    }

    var message: String {
        switch self {
        case .hostMissing(let hostKey):
            return "Configured remote host '\(hostKey)' is missing."
        case .hostOffline(let hostLabel):
            return "Remote host '\(hostLabel)' is currently offline."
        case .pathMissing(let path):
            return "Document path '\(path)' does not exist."
        case .accessFailed(let detail):
            let trimmed = detail.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "Document access failed." : trimmed
        }
    }

    static func preflightIssue(
        ref: DocumentRef,
        hostsConfig: HostsConfig,
        offlineHostnames: Set<String>
    ) -> WorkbenchV2DocumentRestoreIssue? {
        guard case .remote(let hostKey) = ref.target else {
            return nil
        }

        guard let host = hostsConfig.host(id: hostKey) else {
            return .hostMissing(hostKey)
        }

        if offlineHostnames.contains(host.hostname) {
            return .hostOffline(host.id)
        }

        return nil
    }

    static func loadIssue(
        for error: Error,
        ref: DocumentRef
    ) -> WorkbenchV2DocumentRestoreIssue {
        if let loadError = error as? WorkbenchV2DocumentLoadError {
            switch loadError {
            case .missingRemoteHostKey(let hostKey):
                return .hostMissing(hostKey)
            case .fileNotFound(let path):
                return .pathMissing(path)
            case .remoteCommandFailed(_, let message):
                if message.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "file not found" {
                    return .pathMissing(ref.path)
                }
                return .accessFailed(loadError.localizedDescription)
            case .directoryNotSupported,
                 .unsupportedEncoding,
                 .localReadFailed:
                return .accessFailed(loadError.localizedDescription)
            }
        }

        return .accessFailed(error.localizedDescription)
    }
}

enum WorkbenchDocumentLoadPhaseV2: Equatable {
    case loading
    case loaded(WorkbenchV2DocumentSnapshot)
    case failed(WorkbenchV2DocumentRestoreIssue)
}

@MainActor
@Observable
final class WorkbenchV2DocumentLoadCoordinator {
    typealias Loader = @Sendable (DocumentRef, HostsConfig) async throws -> WorkbenchV2DocumentSnapshot

    private let loader: Loader
    private(set) var currentToken: WorkbenchV2DocumentLoadToken?
    private(set) var phase: WorkbenchDocumentLoadPhaseV2 = .loading

    init(
        loader: @escaping Loader = { ref, hostsConfig in
            try await WorkbenchV2DocumentLoadCoordinator.defaultLoader(
                ref: ref,
                hostsConfig: hostsConfig
            )
        }
    ) {
        self.loader = loader
    }

    func begin(token: WorkbenchV2DocumentLoadToken) {
        currentToken = token
        phase = .loading
    }

    func load(
        token: WorkbenchV2DocumentLoadToken,
        ref: DocumentRef,
        hostsConfig: HostsConfig,
        offlineHostnames: Set<String> = []
    ) async {
        begin(token: token)

        if let issue = WorkbenchV2DocumentRestoreIssue.preflightIssue(
            ref: ref,
            hostsConfig: hostsConfig,
            offlineHostnames: offlineHostnames
        ) {
            commitIfCurrent(token) {
                phase = .failed(issue)
            }
            return
        }

        do {
            let snapshot = try await loader(ref, hostsConfig)
            commitIfCurrent(token) {
                phase = .loaded(snapshot)
            }
        } catch {
            let issue = WorkbenchV2DocumentRestoreIssue.loadIssue(for: error, ref: ref)
            commitIfCurrent(token) {
                phase = .failed(issue)
            }
        }
    }

    private func commitIfCurrent(
        _ token: WorkbenchV2DocumentLoadToken,
        update: () -> Void
    ) {
        guard currentToken == token, !Task.isCancelled else {
            return
        }
        update()
    }

    private nonisolated static func defaultLoader(
        ref: DocumentRef,
        hostsConfig: HostsConfig
    ) async throws -> WorkbenchV2DocumentSnapshot {
        try await WorkbenchV2DocumentLoader().load(
            ref: ref,
            hostsConfig: hostsConfig
        )
    }
}

struct WorkbenchDocumentTileViewV2: View {
    let tile: WorkbenchTile
    let ref: DocumentRef
    let isFocused: Bool
    let hostsConfig: HostsConfig

    @Environment(WorkbenchStoreV2.self) private var store
    @Environment(TerminalRuntimeStore.self) private var runtimeStore
    @State private var loadCoordinator = WorkbenchV2DocumentLoadCoordinator()
    @State private var retryGeneration = 0
    @State private var isPresentingRebindSheet = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            tileBackground

            content
                .padding(.top, 72)
                .padding(.horizontal, 16)
                .padding(.bottom, 16)

            header
                .padding(16)
        }
        .overlay(tileBorder)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(8)
        .contentShape(Rectangle())
        .onTapGesture {
            store.focusTile(id: tile.id)
        }
        .onChange(of: loadRequest) { _, newRequest in
            loadCoordinator.begin(token: newRequest.token)
        }
        .task(id: loadRequest) {
            if loadRequest.shouldDeferLoad(hostsConfig: hostsConfig) {
                loadCoordinator.begin(token: loadRequest.token)
                return
            }
            await loadCoordinator.load(
                token: loadRequest.token,
                ref: ref,
                hostsConfig: hostsConfig,
                offlineHostnames: loadRequest.offlineHostnames
            )
        }
        .sheet(isPresented: $isPresentingRebindSheet) {
            WorkbenchDocumentRebindSheetV2(
                tileID: tile.id,
                initialRef: ref,
                hostsConfig: hostsConfig
            )
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.workspaceTilePrefix + tile.id.uuidString)
        .accessibilityLabel(tile.kind.displayTitle)
        .accessibilityValue(accessibilityValue)
    }

    @ViewBuilder
    private var content: some View {
        switch loadCoordinator.phase {
        case .loading:
            VStack(alignment: .leading, spacing: 10) {
                ProgressView()
                    .progressViewStyle(.circular)
                    .tint(.white)
                Text("Loading document…")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.72))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

        case .loaded(let snapshot):
            ScrollView {
                Text(snapshot.text)
                    .font(.system(size: 12, weight: .regular, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.88))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

        case .failed(let issue):
            restoreIssueBody(issue)
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "doc.text")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.88))

            VStack(alignment: .leading, spacing: 3) {
                Text(tile.kind.displayTitle)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.94))
                    .lineLimit(1)

                Text(tile.kind.detailText)
                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.68))
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            Text(ref.target.label)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(Color.white.opacity(0.76))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.black.opacity(0.22), in: Capsule(style: .continuous))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.black.opacity(0.30), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var loadToken: WorkbenchV2DocumentLoadToken {
        WorkbenchV2DocumentLoadToken(tileID: tile.id, ref: ref, attempt: retryGeneration)
    }

    private var loadRequest: WorkbenchV2DocumentLoadRequest {
        WorkbenchV2DocumentLoadRequest(
            token: loadToken,
            offlineHostnames: runtimeStore.offlineHosts,
            inventoryReady: runtimeStore.hasCompletedInitialFetch
        )
    }

    private var accessibilityValue: String {
        switch loadCoordinator.phase {
        case .loading:
            return "Loading document"
        case .loaded:
            return "Document loaded"
        case .failed(let issue):
            return "\(issue.title): \(issue.message)"
        }
    }

    private func restoreIssueBody(_ issue: WorkbenchV2DocumentRestoreIssue) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(issue.title, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.92))

            Text(issue.message)
                .font(.system(size: 12, weight: .regular, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.82))
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                issueActionButton("Retry", icon: "arrow.clockwise") {
                    retryLoad()
                }
                issueActionButton("Rebind", icon: "link") {
                    isPresentingRebindSheet = true
                }
                issueActionButton("Remove Tile", icon: "trash") {
                    store.removeTile(id: tile.id)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(Color.red.opacity(0.22), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func issueActionButton(
        _ title: String,
        icon: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.90))
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Color.black.opacity(0.24), in: Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func retryLoad() {
        Task {
            await runtimeStore.onRefreshInventory?()
            await MainActor.run {
                retryGeneration += 1
            }
        }
    }

    private var tileBackground: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [
                        Color.white.opacity(0.08),
                        Color.white.opacity(0.03)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
    }

    private var tileBorder: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .stroke(
                isFocused ? Color.white.opacity(0.18) : Color.white.opacity(0.10),
                lineWidth: 1
            )
    }
}

struct WorkbenchDocumentRebindTargetOptionV2: Identifiable, Hashable {
    static let missingTargetIDPrefix = "missing:"

    let id: String
    let label: String
    let target: TargetRef?
}

struct WorkbenchDocumentRebindSheetV2: View {
    private static let localTargetID = "local"

    let tileID: UUID
    let initialRef: DocumentRef
    let hostsConfig: HostsConfig

    @Environment(WorkbenchStoreV2.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var selectedTargetID: String
    @State private var path: String

    init(
        tileID: UUID,
        initialRef: DocumentRef,
        hostsConfig: HostsConfig
    ) {
        self.tileID = tileID
        self.initialRef = initialRef
        self.hostsConfig = hostsConfig

        let options = Self.targetOptions(hostsConfig: hostsConfig)
        let initialTargetID: String
        switch initialRef.target {
        case .local:
            initialTargetID = Self.localTargetID
        case .remote(let hostKey):
            initialTargetID = options.contains(where: { $0.id == hostKey })
                ? hostKey
                : WorkbenchDocumentRebindTargetOptionV2.missingTargetIDPrefix + hostKey
        }

        _selectedTargetID = State(initialValue: initialTargetID)
        _path = State(initialValue: initialRef.path)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Rebind Document")
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.94))

            VStack(alignment: .leading, spacing: 10) {
                Text("Target")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.72))

                Picker("Target", selection: $selectedTargetID) {
                    ForEach(targetOptions) { option in
                        Text(option.label).tag(option.id)
                    }
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier(AccessibilityID.workspaceDocumentRebindTarget)

                Text("Path")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.72))

                TextField("Path", text: $path)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, weight: .regular, design: .monospaced))
                    .accessibilityIdentifier(AccessibilityID.workspaceDocumentRebindPath)
            }

            HStack(spacing: 10) {
                Spacer(minLength: 0)

                Button("Cancel") {
                    dismiss()
                }

                Button("Apply") {
                    applyRebind()
                }
                .disabled(trimmedPath.isEmpty || selectedTarget == nil)
                .accessibilityIdentifier(AccessibilityID.workspaceDocumentRebindApply)
            }
        }
        .padding(20)
        .frame(minWidth: 360)
        .background(Color.black.opacity(0.94))
    }

    private var targetOptions: [WorkbenchDocumentRebindTargetOptionV2] {
        Self.targetOptions(
            hostsConfig: hostsConfig,
            initialRef: initialRef
        )
    }

    private var trimmedPath: String {
        path.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var selectedTarget: TargetRef? {
        targetOptions.first(where: { $0.id == selectedTargetID })?.target
    }

    private func applyRebind() {
        guard let selectedOption = targetOptions.first(where: { $0.id == selectedTargetID }) else {
            preconditionFailure("WorkbenchDocumentRebindSheetV2 selected target \(selectedTargetID) is invalid")
        }
        guard let selectedTarget = selectedOption.target else {
            preconditionFailure("WorkbenchDocumentRebindSheetV2 requires an explicit valid target selection")
        }

        let trimmedPath = trimmedPath
        precondition(!trimmedPath.isEmpty, "WorkbenchDocumentRebindSheetV2 requires a non-empty path")

        store.rebindDocument(
            tileID: tileID,
            to: DocumentRef(
                target: selectedTarget,
                path: trimmedPath
            )
        )
        dismiss()
    }

    static func targetOptions(
        hostsConfig: HostsConfig,
        initialRef: DocumentRef? = nil
    ) -> [WorkbenchDocumentRebindTargetOptionV2] {
        let local = WorkbenchDocumentRebindTargetOptionV2(
            id: localTargetID,
            label: "local",
            target: .local
        )
        let remotes = hostsConfig.hosts
            .sorted { $0.id < $1.id }
            .map { host in
                WorkbenchDocumentRebindTargetOptionV2(
                    id: host.id,
                    label: host.id,
                    target: .remote(hostKey: host.id)
                )
            }

        let available = [local] + remotes
        guard case .remote(let hostKey)? = initialRef?.target,
              available.contains(where: { $0.id == hostKey }) == false else {
            return available
        }

        let unavailable = WorkbenchDocumentRebindTargetOptionV2(
            id: WorkbenchDocumentRebindTargetOptionV2.missingTargetIDPrefix + hostKey,
            label: "Unavailable: \(hostKey)",
            target: nil
        )
        return [unavailable] + available
    }
}
