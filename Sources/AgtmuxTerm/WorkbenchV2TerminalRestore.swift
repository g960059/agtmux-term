import SwiftUI
import AgtmuxTermCore

enum WorkbenchV2TerminalRestoreIssue: Equatable {
    case daemonUnavailable(String)
    case daemonIncompatible(String)
    case hostMissing(String)
    case hostOffline(String)
    case tmuxUnavailable
    case sessionMissing(String)

    var title: String {
        switch self {
        case .daemonUnavailable:
            return "Daemon unavailable"
        case .daemonIncompatible:
            return "Daemon incompatible"
        case .hostMissing:
            return "Host missing"
        case .hostOffline:
            return "Host offline"
        case .tmuxUnavailable:
            return "tmux unavailable"
        case .sessionMissing:
            return "Session missing"
        }
    }

    var message: String {
        switch self {
        case .daemonUnavailable(let detail),
             .daemonIncompatible(let detail):
            let trimmed = detail.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "Local daemon health is unavailable." : trimmed
        case .hostMissing(let hostKey):
            return "Configured remote host '\(hostKey)' is missing."
        case .hostOffline(let hostKey):
            return "Remote host '\(hostKey)' is currently offline."
        case .tmuxUnavailable:
            return "Local tmux inventory is currently unavailable."
        case .sessionMissing(let sessionName):
            return "tmux session '\(sessionName)' no longer exists."
        }
    }

    static func resolve(
        sessionRef: SessionRef,
        hostsConfig: HostsConfig,
        panes: [AgtmuxPane],
        offlineHostnames: Set<String>,
        localDaemonIssue: LocalDaemonIssue?
    ) -> WorkbenchV2TerminalRestoreIssue? {
        switch sessionRef.target {
        case .local:
            if offlineHostnames.contains("local") {
                return .tmuxUnavailable
            }
            if hasExactSession(
                named: sessionRef.sessionName,
                source: "local",
                panes: panes
            ) {
                return nil
            }
            if let localDaemonIssue {
                switch localDaemonIssue {
                case .localDaemonUnavailable(let detail):
                    return .daemonUnavailable(detail)
                case .incompatibleSyncV2(let detail):
                    return .daemonIncompatible(detail)
                }
            }
            return .sessionMissing(sessionRef.sessionName)

        case .remote(let hostKey):
            guard let host = hostsConfig.host(id: hostKey) else {
                return .hostMissing(hostKey)
            }
            if offlineHostnames.contains(host.hostname) {
                return .hostOffline(host.id)
            }
            guard hasExactSession(
                named: sessionRef.sessionName,
                source: host.hostname,
                panes: panes
            ) else {
                return .sessionMissing(sessionRef.sessionName)
            }
            return nil
        }
    }

    private static func hasExactSession(
        named sessionName: String,
        source: String,
        panes: [AgtmuxPane]
    ) -> Bool {
        panes.contains { pane in
            pane.source == source && pane.sessionName == sessionName
        }
    }
}

enum WorkbenchV2TerminalTileState: Equatable {
    case bootstrapping
    case ready
    case broken(WorkbenchV2TerminalRestoreIssue)

    static func resolve(
        sessionRef: SessionRef,
        hostsConfig: HostsConfig,
        panes: [AgtmuxPane],
        offlineHostnames: Set<String>,
        localDaemonIssue: LocalDaemonIssue?,
        inventoryReady: Bool
    ) -> WorkbenchV2TerminalTileState {
        if !inventoryReady {
            if case .remote(let hostKey) = sessionRef.target,
               hostsConfig.host(id: hostKey) == nil {
                return .broken(.hostMissing(hostKey))
            }
            return .bootstrapping
        }

        if let issue = WorkbenchV2TerminalRestoreIssue.resolve(
            sessionRef: sessionRef,
            hostsConfig: hostsConfig,
            panes: panes,
            offlineHostnames: offlineHostnames,
            localDaemonIssue: localDaemonIssue
        ) {
            return .broken(issue)
        }

        return .ready
    }
}

struct WorkbenchV2TerminalRebindOption: Identifiable, Hashable {
    let id: String
    let label: String
    let ref: SessionRef

    static func liveOptions(
        panes: [AgtmuxPane],
        hostsConfig: HostsConfig,
        offlineHostnames: Set<String> = [],
        inventoryReady: Bool = true
    ) -> [WorkbenchV2TerminalRebindOption] {
        guard inventoryReady else {
            return []
        }

        let livePanes = panes.filter { pane in
            !offlineHostnames.contains(pane.source)
        }

        let sortedPanes = livePanes.sorted { lhs, rhs in
            let lhsSource = sourceSortKey(for: lhs, hostsConfig: hostsConfig)
            let rhsSource = sourceSortKey(for: rhs, hostsConfig: hostsConfig)
            if lhsSource != rhsSource {
                return lhsSource < rhsSource
            }
            if lhs.sessionName != rhs.sessionName {
                return lhs.sessionName.localizedCaseInsensitiveCompare(rhs.sessionName) == .orderedAscending
            }
            return lhs.paneId < rhs.paneId
        }

        var orderedKeys: [String] = []
        var optionsByID: [String: WorkbenchV2TerminalRebindOption] = [:]

        for pane in sortedPanes {
            let target: TargetRef = pane.source == "local"
                ? .local
                : .remote(hostKey: hostsConfig.remoteHostKey(for: pane.source))
            var ref = SessionRef(
                target: target,
                sessionName: pane.sessionName
            )
            ref.lastSeenRepoRoot = pane.currentPath

            let id = optionID(for: ref)
            guard optionsByID[id] == nil else {
                continue
            }

            let label = "\(target.label) • \(pane.sessionName)"
            optionsByID[id] = WorkbenchV2TerminalRebindOption(
                id: id,
                label: label,
                ref: ref
            )
            orderedKeys.append(id)
        }

        return orderedKeys.compactMap { optionsByID[$0] }
    }

    static func optionID(for ref: SessionRef) -> String {
        switch ref.target {
        case .local:
            return "local:\(ref.sessionName)"
        case .remote(let hostKey):
            return "remote:\(hostKey):\(ref.sessionName)"
        }
    }

    private static func sourceSortKey(
        for pane: AgtmuxPane,
        hostsConfig: HostsConfig
    ) -> String {
        if pane.source == "local" {
            return "0:local"
        }
        return "1:\(hostsConfig.remoteHostKey(for: pane.source))"
    }
}

struct WorkbenchTerminalRebindSheetV2: View {
    let tileID: UUID
    let initialRef: SessionRef
    let hostsConfig: HostsConfig

    @Environment(WorkbenchStoreV2.self) private var store
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var viewModel: AppViewModel

    @State private var selectedOptionID: String

    init(
        tileID: UUID,
        initialRef: SessionRef,
        hostsConfig: HostsConfig
    ) {
        self.tileID = tileID
        self.initialRef = initialRef
        self.hostsConfig = hostsConfig
        _selectedOptionID = State(initialValue: WorkbenchV2TerminalRebindOption.optionID(for: initialRef))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Rebind Terminal")
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.94))

            if rebindOptions.isEmpty {
                Text("No live tmux sessions are available for exact-target rebind.")
                    .font(.system(size: 12, weight: .regular, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.80))
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Exact target")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.white.opacity(0.72))

                    Picker("Exact target", selection: $selectedOptionID) {
                        ForEach(rebindOptions) { option in
                            Text(option.label).tag(option.id)
                        }
                    }
                    .pickerStyle(.menu)
                    .accessibilityIdentifier(AccessibilityID.workspaceTerminalRebindTarget)
                }
            }

            HStack(spacing: 10) {
                Spacer(minLength: 0)

                Button("Cancel") {
                    dismiss()
                }
                .buttonStyle(.borderless)

                Button("Rebind") {
                    applyRebind()
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedOption == nil)
                .accessibilityIdentifier(AccessibilityID.workspaceTerminalRebindApply)
            }
        }
        .padding(20)
        .frame(minWidth: 360)
        .background(
            LinearGradient(
                colors: [
                    Color.black.opacity(0.92),
                    Color(red: 0.14, green: 0.16, blue: 0.20)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .onAppear {
            repairSelectionIfNeeded()
        }
        .onChange(of: rebindOptions) { _, _ in
            repairSelectionIfNeeded()
        }
    }

    private var rebindOptions: [WorkbenchV2TerminalRebindOption] {
        WorkbenchV2TerminalRebindOption.liveOptions(
            panes: viewModel.panes,
            hostsConfig: hostsConfig,
            offlineHostnames: viewModel.offlineHosts,
            inventoryReady: viewModel.hasCompletedInitialFetch
        )
    }

    private var selectedOption: WorkbenchV2TerminalRebindOption? {
        rebindOptions.first(where: { $0.id == selectedOptionID }) ?? rebindOptions.first
    }

    private func repairSelectionIfNeeded() {
        guard !rebindOptions.isEmpty else { return }
        if rebindOptions.contains(where: { $0.id == selectedOptionID }) {
            return
        }
        selectedOptionID = rebindOptions[0].id
    }

    private func applyRebind() {
        guard let selectedOption else {
            return
        }
        store.rebindTerminal(tileID: tileID, to: selectedOption.ref)
        dismiss()
    }
}
