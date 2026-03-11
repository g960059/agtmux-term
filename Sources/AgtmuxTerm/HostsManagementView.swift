import SwiftUI

struct HostsManagementView: View {
    @EnvironmentObject var viewModel: AppViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var hostname = ""
    @State private var username = ""
    @State private var displayName = ""
    @State private var transport: RemoteHost.Transport = .ssh

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Text("SSH Targets")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.92))
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(.bordered)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)

            Divider().opacity(0.2)

            // Existing hosts
            if viewModel.hostsConfig.hosts.isEmpty {
                Text("No targets configured.")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.white.opacity(0.56))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
            } else {
                ForEach(viewModel.hostsConfig.hosts) { host in
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(host.displayName ?? host.hostname)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(Color.white.opacity(0.88))
                            Text("\(host.transport.rawValue) · \(host.sshTarget)")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(Color.white.opacity(0.52))
                        }
                        Spacer()
                        Button {
                            viewModel.removeHost(id: host.id)
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .foregroundStyle(Color.red.opacity(0.72))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    Divider().opacity(0.12)
                }
            }

            Divider().opacity(0.2)

            // Add form
            VStack(alignment: .leading, spacing: 12) {
                Text("Add Target")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.56))
                    .textCase(.uppercase)

                VStack(spacing: 8) {
                    HStack {
                        Text("Hostname")
                            .frame(width: 90, alignment: .leading)
                            .font(.system(size: 12))
                            .foregroundStyle(Color.white.opacity(0.72))
                        TextField("e.g. utm-vm", text: $hostname)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12, design: .monospaced))
                    }
                    HStack {
                        Text("Username")
                            .frame(width: 90, alignment: .leading)
                            .font(.system(size: 12))
                            .foregroundStyle(Color.white.opacity(0.72))
                        TextField("optional", text: $username)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12, design: .monospaced))
                    }
                    HStack {
                        Text("Display Name")
                            .frame(width: 90, alignment: .leading)
                            .font(.system(size: 12))
                            .foregroundStyle(Color.white.opacity(0.72))
                        TextField("optional", text: $displayName)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12, design: .monospaced))
                    }
                    HStack {
                        Text("Transport")
                            .frame(width: 90, alignment: .leading)
                            .font(.system(size: 12))
                            .foregroundStyle(Color.white.opacity(0.72))
                        Picker("", selection: $transport) {
                            Text("SSH").tag(RemoteHost.Transport.ssh)
                            Text("Mosh").tag(RemoteHost.Transport.mosh)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(maxWidth: 140)
                    }
                }

                Button("Add Target") {
                    let host = RemoteHost(
                        id: hostname.lowercased().replacingOccurrences(of: " ", with: "-"),
                        displayName: displayName.isEmpty ? nil : displayName,
                        hostname: hostname,
                        user: username.isEmpty ? nil : username,
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
            .padding(16)
        }
        .frame(width: 360)
        .preferredColorScheme(.dark)
    }
}
