import AppKit
import SwiftUI

@MainActor
final class WindowChromeController: NSObject {
    private weak var window: NSWindow?
    private let chromeState: CockpitChromeState
    private let viewModel: AppViewModel
    private let workbenchStoreV2: WorkbenchStoreV2

    private let accessoryController = NSTitlebarAccessoryViewController()
    private let accessoryView = TrafficLightAwareAccessoryView(frame: .zero)
    private var observers: [NSObjectProtocol] = []

    init(
        chromeState: CockpitChromeState,
        viewModel: AppViewModel,
        workbenchStoreV2: WorkbenchStoreV2
    ) {
        self.chromeState = chromeState
        self.viewModel = viewModel
        self.workbenchStoreV2 = workbenchStoreV2
        super.init()
    }

    func install(on window: NSWindow) {
        self.window = window

        let rootView = TitlebarChromeView()
            .environmentObject(viewModel)
            .environment(workbenchStoreV2)
            .environment(chromeState)
        let hostingView = NSHostingView(rootView: rootView)
        accessoryView.embed(hostingView)

        accessoryController.layoutAttribute = .top
        accessoryController.fullScreenMinHeight = 24
        accessoryController.view = accessoryView

        window.addTitlebarAccessoryViewController(accessoryController)
        installObservers(for: window)

        DispatchQueue.main.async { [weak self] in
            self?.updateMetrics()
        }
    }

    private func installObservers(for window: NSWindow) {
        let center = NotificationCenter.default
        let names: [NSNotification.Name] = [
            NSWindow.didResizeNotification,
            NSWindow.didMoveNotification,
            NSWindow.didEndLiveResizeNotification,
            NSWindow.didEnterFullScreenNotification,
            NSWindow.didExitFullScreenNotification,
            NSWindow.didChangeBackingPropertiesNotification
        ]
        for name in names {
            let token = center.addObserver(
                forName: name,
                object: window,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.updateMetrics()
                }
            }
            observers.append(token)
        }
    }

    private func updateMetrics() {
        guard let window else { return }

        let titlebarHeight = max(24, window.frame.height - window.contentLayoutRect.height)
        chromeState.titlebarHeight = titlebarHeight
        sizeAccessory(width: window.frame.width, height: titlebarHeight)

        let accessoryFrameInWindow = accessoryView.convert(accessoryView.bounds, to: nil)
        chromeState.titlebarAccessoryMinXInWindow = max(0, accessoryFrameInWindow.minX)

        guard let trafficLightsRectInWindow = trafficLightsRectInWindowCoordinates(window: window) else {
            chromeState.trafficLightsTrailingXInAccessory = max(
                0,
                72 - chromeState.titlebarAccessoryMinXInWindow
            )
            accessoryView.trafficLightsExclusionRect = .zero
            return
        }

        chromeState.trafficLightsTrailingXInAccessory = max(
            0,
            trafficLightsRectInWindow.maxX - chromeState.titlebarAccessoryMinXInWindow
        )

        let titlebarMidY = window.contentLayoutRect.maxY + (titlebarHeight * 0.5)
        chromeState.yOffset = trafficLightsRectInWindow.midY - titlebarMidY

        // Keep exclusion hit test rect in accessory-local coordinates.
        let trafficLightsRectInAccessory = accessoryView.convert(
            trafficLightsRectInWindow,
            from: nil
        )
        let accessoryBounds = NSRect(x: 0, y: 0, width: accessoryView.bounds.width, height: titlebarHeight)
        var exclusionRect = trafficLightsRectInAccessory
            .insetBy(dx: -1, dy: -1)
            .intersection(accessoryBounds)

        // Guardrail: exclusion rect must never overlap the first icon hit area.
        let iconGap: CGFloat = 6
        let firstIconMinX = chromeState.trafficLightsTrailingXInAccessory + iconGap
        let maxAllowedExclusionX = max(0, firstIconMinX - 1)
        if !exclusionRect.isNull, exclusionRect.maxX > maxAllowedExclusionX {
            exclusionRect.size.width = max(0, maxAllowedExclusionX - exclusionRect.minX)
        }

        if exclusionRect.isNull || exclusionRect.width <= 0 {
            accessoryView.trafficLightsExclusionRect = .zero
        } else {
            accessoryView.trafficLightsExclusionRect = exclusionRect
        }
    }

    private func sizeAccessory(width: CGFloat, height: CGFloat) {
        accessoryView.frame = NSRect(x: 0, y: 0, width: width, height: height)
        accessoryController.view.frame = accessoryView.frame
    }

    private func trafficLightsRectInWindowCoordinates(window: NSWindow) -> NSRect? {
        guard
            let close = window.standardWindowButton(.closeButton),
            let mini = window.standardWindowButton(.miniaturizeButton),
            let zoom = window.standardWindowButton(.zoomButton),
            let referenceSuperview = close.superview
        else {
            return nil
        }

        let rectsInReference = [close, mini, zoom].compactMap { button -> NSRect? in
            guard button.window === window else { return nil }
            if button.superview === referenceSuperview {
                return button.frame
            }
            // Normalize all buttons into a single reference view first.
            return button.convert(button.bounds, to: referenceSuperview)
        }
        guard let first = rectsInReference.first else { return nil }
        let unionInReference = rectsInReference.dropFirst().reduce(first) { partial, next in
            partial.union(next)
        }
        return referenceSuperview.convert(unionInReference, to: nil)
    }
}

private final class TrafficLightAwareAccessoryView: NSView {
    var trafficLightsExclusionRect: NSRect = .zero

    override var mouseDownCanMoveWindow: Bool { false }

    func embed(_ child: NSView) {
        subviews.forEach { $0.removeFromSuperview() }

        child.translatesAutoresizingMaskIntoConstraints = false
        addSubview(child)
        NSLayoutConstraint.activate([
            child.leadingAnchor.constraint(equalTo: leadingAnchor),
            child.trailingAnchor.constraint(equalTo: trailingAnchor),
            child.topAnchor.constraint(equalTo: topAnchor),
            child.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        if trafficLightsExclusionRect.contains(point) {
            return nil
        }
        return super.hitTest(point)
    }
}
