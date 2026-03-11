# Handoff: T-SM03 — Provider-Left Status Badge (1-line compact sidebar row)

**Task**: Redesign PaneRowView layout — provider icon moves to LEFT with status ring, keep 1 line per pane.

**User requirement**: "pane itemは1行で表示。provider markは左側に表示し、runningなどのstatusはprovider markのring/circular progressのように表示"

---

## Current Layout

```
[● dot] title                    [provider icon] [2m]
```

- LEFT: `stateIndicator` — 10×10 dot/spinner/icon indicating running/waiting/error
- CENTER: title text
- RIGHT: ProviderIcon + FreshnessLabel

## Target Layout (1-line compact)

```
[provider+ring] title                              [2m]
```

- LEFT: `ProviderStatusBadge` — provider icon (18×18) with colored ring indicating status
- CENTER: title text (wider, more space)
- RIGHT: FreshnessLabel (age)
- Unmanaged pane: no left badge, just title

---

## New Component: ProviderStatusBadge

Create `struct ProviderStatusBadge: View` in SidebarView.swift (or a dedicated file).

```swift
struct ProviderStatusBadge: View {
    let provider: Provider
    let primaryState: PanePresentationPrimaryState
    var iconSize: CGFloat = 16
    var ringDiameter: CGFloat = 22

    var body: some View {
        ZStack {
            // Status ring
            ringView
            // Provider icon centered
            ProviderIcon(provider: provider, size: iconSize)
        }
        .frame(width: ringDiameter, height: ringDiameter)
    }

    @ViewBuilder
    private var ringView: some View {
        switch primaryState {
        case .running:
            // Animated spinning arc (similar to existing SpinnerView)
            SpinnerRing(diameter: ringDiameter, color: .green, lineWidth: 2)
        case .waitingApproval:
            Circle()
                .strokeBorder(Color.orange, lineWidth: 2)
        case .waitingUserInput:
            Circle()
                .strokeBorder(Color.yellow, lineWidth: 2)
        case .error:
            Circle()
                .strokeBorder(Color.red, lineWidth: 2)
        case .completedIdle, .idle:
            Circle()
                .strokeBorder(Color.white.opacity(0.2), lineWidth: 1.5)
        case .inactive:
            EmptyView()
        }
    }
}
```

### SpinnerRing
If the existing `SpinnerView` is already an animated ring/arc, reuse its animation logic. Otherwise, create `SpinnerRing`:

```swift
struct SpinnerRing: View {
    let diameter: CGFloat
    let color: Color
    var lineWidth: CGFloat = 2
    @State private var rotation: Double = 0

    var body: some View {
        Circle()
            .trim(from: 0, to: 0.7)
            .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            .frame(width: diameter, height: diameter)
            .rotationEffect(.degrees(rotation))
            .onAppear {
                withAnimation(.linear(duration: 1.0).repeatForever(autoreverses: false)) {
                    rotation = 360
                }
            }
    }
}
```

Check whether `SpinnerView` (used in current stateIndicator) already does this — if so, adapt it for the ring use case rather than duplicating.

---

## PaneRowView Changes

### Replace LEFT section

Remove:
```swift
// Activity state indicator (fixed-width slot)
stateIndicator
    .frame(width: 10, height: 10)
```

Add:
```swift
// Provider badge with status ring (managed panes only)
if isManaged, let provider {
    ProviderStatusBadge(provider: provider, primaryState: primaryState)
}
```

### Remove RIGHT provider icon

Remove:
```swift
// Provider icon (managed panes only)
if let provider {
    ProviderIcon(provider: provider)
}
```

### Adjust spacing and padding

```swift
HStack(spacing: 8) {       // was 10
    // ...
}
.padding(.horizontal, 10)
.padding(.vertical, 5)     // uniform for managed/unmanaged
.padding(.leading, 8)      // was 10, tighter now
.frame(maxWidth: .infinity, alignment: .leading)
```

### Keep unmanaged pane layout simple

For unmanaged panes (`!isManaged`):
- No badge on left
- Just title + no freshness
- Keep existing appearance

---

## Acceptance Criteria

1. `swift build` PASS
2. `swift test` PASS (deterministic — 299+ tests)
3. Managed pane shows: provider icon on left with colored ring indicating state
   - Running: animated spinning green arc
   - WaitingApproval: solid orange ring
   - WaitingInput: solid yellow ring
   - Error: solid red ring
   - Idle: dim white ring (low opacity)
4. Provider icon is NOT shown on the right side anymore
5. Unmanaged pane layout unchanged (no badge)
6. 1-line height — no VStack, no subtitle line in the row itself
7. Subtitle accessible via tooltip (already in `tooltipText` — optionally add subtitle there)

---

## Commit Message

```
feat: sidebar 1-line compact row — provider+status ring on left (T-SM03)
```
