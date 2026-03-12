import SwiftUI

// MARK: - SettingsView

struct SettingsView: View {
    @EnvironmentObject var viewModel: AppViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Settings")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.92))
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(.bordered)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            Divider().opacity(0.2)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    // MARK: SSH Targets
                    settingsSection("SSH Targets") {
                        SSHTargetsSection()
                            .environmentObject(viewModel)
                    }

                    sectionDivider()

                    // MARK: Claude Hooks
                    settingsSection("Claude Hooks") {
                        HooksSection()
                            .environmentObject(viewModel)
                    }

                    sectionDivider()

                    // MARK: Session
                    settingsSection("Session") {
                        SessionSection()
                            .environmentObject(viewModel)
                    }
                }
                .padding(.bottom, 16)
            }
        }
        .frame(minWidth: 440, minHeight: 480)
        .preferredColorScheme(.dark)
    }

    private func settingsSection<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.44))
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 8)
            content()
        }
    }

    private func sectionDivider() -> some View {
        Divider().opacity(0.12).padding(.horizontal, 20).padding(.top, 8)
    }
}

// MARK: - SSH Targets Section

private struct SSHTargetsSection: View {
    @EnvironmentObject var viewModel: AppViewModel
    @Environment(TerminalRuntimeStore.self) private var runtimeStore
    @State private var hostname = ""
    @State private var username = ""
    @State private var displayName = ""
    @State private var transport: RemoteHost.Transport = .ssh

    var body: some View {
        VStack(spacing: 0) {
            if runtimeStore.hostsConfig.hosts.isEmpty {
                Text("No SSH targets configured.")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.white.opacity(0.48))
                    .padding(.horizontal, 20)
                    .padding(.bottom, 12)
            } else {
                ForEach(runtimeStore.hostsConfig.hosts) { host in
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(host.displayName ?? host.hostname)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(Color.white.opacity(0.88))
                            Text("\(host.transport.rawValue) · \(host.sshTarget)")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(Color.white.opacity(0.48))
                        }
                        Spacer()
                        Button {
                            viewModel.removeHost(id: host.id)
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .foregroundStyle(Color.red.opacity(0.72))
                                .font(.system(size: 15))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 9)
                    Divider().opacity(0.1).padding(.leading, 20)
                }
            }

            // Add form
            VStack(alignment: .leading, spacing: 8) {
                Text("Add Target")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.56))

                formRow("Hostname") {
                    TextField("e.g. utm-vm", text: $hostname)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                }
                formRow("Username") {
                    TextField("optional", text: $username)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                }
                formRow("Display Name") {
                    TextField("optional", text: $displayName)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                }
                formRow("Transport") {
                    Picker("", selection: $transport) {
                        Text("SSH").tag(RemoteHost.Transport.ssh)
                        Text("Mosh").tag(RemoteHost.Transport.mosh)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 140)
                }

                Button("Add Target") {
                    let id = hostname.lowercased()
                        .trimmingCharacters(in: .whitespaces)
                        .replacingOccurrences(of: " ", with: "-")
                    let host = RemoteHost(
                        id: id,
                        displayName: displayName.trimmingCharacters(in: .whitespaces).isEmpty
                            ? nil : displayName.trimmingCharacters(in: .whitespaces),
                        hostname: hostname.trimmingCharacters(in: .whitespaces),
                        user: username.trimmingCharacters(in: .whitespaces).isEmpty
                            ? nil : username.trimmingCharacters(in: .whitespaces),
                        transport: transport
                    )
                    viewModel.addHost(host)
                    hostname = ""
                    username = ""
                    displayName = ""
                    transport = .ssh
                }
                .disabled(hostname.trimmingCharacters(in: .whitespaces).isEmpty)
                .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
        }
    }

    private func formRow<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .frame(width: 90, alignment: .leading)
                .font(.system(size: 12))
                .foregroundStyle(Color.white.opacity(0.68))
            content()
        }
    }
}

// MARK: - Hooks Section

private struct HooksSection: View {
    @EnvironmentObject var viewModel: AppViewModel
    @Environment(HealthAndHooksStore.self) private var healthStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Status row
            HStack(spacing: 8) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                Text(statusLabel)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.white.opacity(0.82))
                Spacer()
                if healthStore.hookSetupStatus == .checking {
                    ProgressView().scaleEffect(0.7)
                }
            }

            if let detail = statusDetail {
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.white.opacity(0.52))
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Action buttons
            HStack(spacing: 8) {
                Button("Register") {
                    Task { await viewModel.registerHooks() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(healthStore.hookSetupStatus == .checking || healthStore.hookSetupStatus == .unavailable)

                Button("Unregister") {
                    Task { await viewModel.unregisterHooks() }
                }
                .buttonStyle(.bordered)
                .disabled(healthStore.hookSetupStatus == .checking || healthStore.hookSetupStatus == .unavailable)

                Button("Verify") {
                    Task { await viewModel.performStartupHookCheck() }
                }
                .buttonStyle(.bordered)
                .disabled(healthStore.hookSetupStatus == .checking || healthStore.hookSetupStatus == .unavailable)
            }
        }
        .padding(.horizontal, 20)
    }

    private var statusLabel: String {
        switch healthStore.hookSetupStatus {
        case .unknown:      return "Status unknown"
        case .checking:     return "Checking…"
        case .registered:   return "Hooks registered"
        case .missing:      return "Hooks not registered"
        case .unavailable:  return "agtmux binary unavailable"
        }
    }

    private var statusColor: Color {
        switch healthStore.hookSetupStatus {
        case .registered:   return .green
        case .missing:      return .orange
        case .unavailable:  return .red
        case .checking, .unknown: return Color.white.opacity(0.3)
        }
    }

    private var statusDetail: String? {
        switch healthStore.hookSetupStatus {
        case .missing:
            return "Claude Code hooks are not installed. Register them so agtmux receives live activity events."
        case .unavailable:
            return "The agtmux binary was not found. Ensure it is installed and AGTMUX_BIN is set if needed."
        default:
            return nil
        }
    }
}

// MARK: - Session Section

private struct SessionSection: View {
    @EnvironmentObject var viewModel: AppViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Auto-launch session name")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.white.opacity(0.82))
                Text("When no local tmux sessions exist, agtmux-term will create a session with this name on startup.")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.white.opacity(0.48))
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                TextField("main", text: $viewModel.autoLaunchSessionName)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 13, design: .monospaced))
                    .frame(maxWidth: 200)

                if viewModel.autoLaunchSessionName.trimmingCharacters(in: .whitespaces).isEmpty {
                    Text("Leave empty to disable")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.white.opacity(0.38))
                }
            }
        }
        .padding(.horizontal, 20)
    }
}
