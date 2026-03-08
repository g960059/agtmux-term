import SwiftUI
import AgtmuxTermCore

struct WorkbenchTabBarV2: View {
    @Environment(WorkbenchStoreV2.self) private var store

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(Array(store.workbenches.enumerated()), id: \.element.id) { index, workbench in
                        WorkbenchTabButtonV2(
                            workbench: workbench,
                            isActive: index == store.activeWorkbenchIndex,
                            onSelect: { store.switchWorkbench(to: workbench.id) },
                            onClose: { store.closeWorkbench(id: workbench.id) }
                        )
                    }
                }
                .padding(.trailing, 2)
            }

            Spacer(minLength: 0)

            Button(action: { store.createWorkbench() }) {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .medium))
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.white.opacity(0.62))
            .accessibilityLabel("New Workbench")
            .accessibilityIdentifier(AccessibilityID.workspaceNewTab)
            .padding(.trailing, 6)
        }
        .accessibilityIdentifier(AccessibilityID.workspaceTabBar)
    }
}

private struct WorkbenchTabButtonV2: View {
    let workbench: Workbench
    let isActive: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 4) {
            Text(workbench.displayTitle)
                .font(.system(size: 12, weight: isActive ? .semibold : .regular, design: .rounded))
                .foregroundStyle(isActive ? Color.white.opacity(0.92) : Color.white.opacity(0.78))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: 160, alignment: .leading)

            if isHovered || isActive {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(Color.white.opacity(isHovered ? 0.6 : 0.42))
                        .frame(width: 12, height: 12)
                }
                .buttonStyle(.plain)
            } else {
                Spacer().frame(width: 12)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 25)
        .background(
            UnevenRoundedRectangle(
                cornerRadii: .init(topLeading: 7, bottomLeading: 0, bottomTrailing: 0, topTrailing: 7),
                style: .continuous
            )
            .fill(tabBackground)
        )
        .overlay(
            UnevenRoundedRectangle(
                cornerRadii: .init(topLeading: 7, bottomLeading: 0, bottomTrailing: 0, topTrailing: 7),
                style: .continuous
            )
            .stroke(isActive ? Color.white.opacity(0.08) : Color.clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { isHovered = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(AccessibilityID.workspaceTabPrefix + workbench.id.uuidString)
    }

    private var tabBackground: Color {
        if isActive { return Color.black.opacity(0.14) }
        if isHovered { return Color.white.opacity(0.05) }
        return Color.clear
    }
}
