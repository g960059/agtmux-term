import SwiftUI

// MARK: - FilterBarView

/// Horizontal tab bar for switching between StatusFilter modes.
struct FilterBarView: View {
    @EnvironmentObject var viewModel: AppViewModel

    var body: some View {
        HStack(spacing: 0) {
            ForEach(StatusFilter.allCases, id: \.self) { filter in
                Button(action: { viewModel.statusFilter = filter }) {
                    Text(filter.displayName)
                        .font(.system(size: 12, weight: viewModel.statusFilter == filter ? .semibold : .regular))
                        .padding(.vertical, 5)
                        .padding(.horizontal, 10)
                }
                .buttonStyle(.plain)
                .background(
                    viewModel.statusFilter == filter
                        ? Color.accentColor.opacity(0.15)
                        : Color.clear
                )
                .cornerRadius(4)
            }
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }
}

// MARK: - SessionRowView

/// A single row representing one tmux pane in the sidebar list.
struct SessionRowView: View {
    let pane: AgtmuxPane
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 8) {
            // Activity state color indicator
            Circle()
                .fill(pane.activityState.indicatorColor)
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 2) {
                // Primary label: conversation title or pane ID fallback
                Text(pane.conversationTitle ?? pane.paneId)
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .truncationMode(.tail)

                // Secondary label: session:windowIndex
                Text("\(pane.sessionName):\(pane.windowId)")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            // Presence badge (e.g. "claude")
            if let presence = pane.presence {
                Text(presence)
                    .font(.system(size: 10, weight: .medium))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.2))
                    .cornerRadius(4)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(isSelected ? Color.accentColor.opacity(0.12) : Color.clear)
        .cornerRadius(6)
    }
}

// MARK: - SidebarView

/// Scrollable pane list with filter bar.
struct SidebarView: View {
    @EnvironmentObject var viewModel: AppViewModel

    var body: some View {
        VStack(spacing: 0) {
            FilterBarView()
            Divider()

            if viewModel.isOffline {
                offlineBanner
            }

            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(viewModel.filteredPanes) { pane in
                        SessionRowView(
                            pane: pane,
                            isSelected: viewModel.selectedPane?.paneId == pane.paneId
                        )
                        .contentShape(Rectangle())
                        .onTapGesture {
                            viewModel.selectPane(pane)
                        }
                    }
                }
                .padding(.vertical, 4)
                .padding(.horizontal, 4)
            }
        }
    }

    private var offlineBanner: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)
                .font(.system(size: 12))
            Text("Daemon offline")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.orange.opacity(0.08))
    }
}

// MARK: - ActivityState display helpers

private extension AgtmuxPane.ActivityState {
    var indicatorColor: Color {
        switch self {
        case .running:          return .green
        case .idle:             return .gray
        case .waitingApproval:  return .orange
        case .waitingInput:     return .yellow
        case .error:            return .red
        case .unknown:          return .gray
        }
    }
}

// MARK: - StatusFilter display helpers

private extension StatusFilter {
    var displayName: String {
        switch self {
        case .all:       return "All"
        case .managed:   return "Managed"
        case .attention: return "Attention"
        case .pinned:    return "Pinned"
        }
    }
}
