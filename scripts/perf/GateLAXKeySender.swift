import AppKit
import ApplicationServices
import Foundation

enum GateLAXKeySenderError: Error, CustomStringConvertible {
    case invalidArgument(String)
    case unsupportedModifier(String)
    case unsupportedSequence(String)
    case invalidFraction(String)
    case invalidPID(String)
    case eventSourceUnavailable
    case eventCreationFailed
    case targetApplicationUnavailable(String)
    case targetApplicationActivationFailed(String)
    case focusedApplicationUnavailable
    case focusedWindowUnavailable
    case focusedWindowFrameUnavailable
    case elementIdentifierMissing
    case targetElementUnavailable(String)

    var description: String {
        switch self {
        case .invalidArgument(let value):
            return "invalid argument: \(value)"
        case .unsupportedModifier(let value):
            return "unsupported modifier: \(value)"
        case .unsupportedSequence(let value):
            return "unsupported sequence: \(value)"
        case .invalidFraction(let value):
            return "invalid fraction: \(value)"
        case .invalidPID(let value):
            return "invalid pid: \(value)"
        case .eventSourceUnavailable:
            return "failed to create CGEventSource"
        case .eventCreationFailed:
            return "failed to create keyboard event"
        case .targetApplicationUnavailable(let value):
            return "failed to resolve target application: \(value)"
        case .targetApplicationActivationFailed(let value):
            return "failed to activate target application: \(value)"
        case .focusedApplicationUnavailable:
            return "failed to resolve focused application"
        case .focusedWindowUnavailable:
            return "failed to resolve focused window"
        case .focusedWindowFrameUnavailable:
            return "failed to resolve focused window frame"
        case .elementIdentifierMissing:
            return "missing target element identifier"
        case .targetElementUnavailable(let identifier):
            return "failed to resolve target element: \(identifier)"
        }
    }
}

struct GateLAXKeySenderResult: Encodable {
    let binaryPath: String
    let bundlePath: String
    let pid: Int32
    let trusted: Bool
    let prompted: Bool
    let sent: Bool
    let dryRun: Bool
    let action: String
    let keyCode: Int
    let scrollLines: Int?
    let modifiers: [String]
    let targetIdentifier: String?
    let clickPoint: ClickPoint?
    let error: String?
}

struct ClickPoint: Encodable {
    let x: Double
    let y: Double
}

struct GateLAXKeySenderOptions {
    enum Action {
        case key
        case clickFrontWindow
        case activateApp
        case sequence
        case focusKeyPoint
        case focusKeyFrontWindow
        case focusKeyIdentifier
        case focusScrollPoint
        case focusScrollFrontWindow
        case focusScrollIdentifier
    }

    var prompt = false
    var dryRun = false
    var action: Action = .key
    var keyCode = 125
    var modifiers: [String] = []
    var xFraction = 0.5
    var yFraction = 0.5
    var targetIdentifier: String?
    var appPID: pid_t?
    var bundleIdentifier: String?
    var sequenceName: String?
    var scrollLines = 0
    var pointX: Double?
    var pointY: Double?
}

func parseOptions(arguments: [String]) throws -> GateLAXKeySenderOptions {
    var options = GateLAXKeySenderOptions()
    var index = 1

    while index < arguments.count {
        let argument = arguments[index]
        switch argument {
        case "--prompt":
            options.prompt = true
            index += 1
        case "--dry-run":
            options.dryRun = true
            index += 1
        case "--click-front-window":
            options.action = .clickFrontWindow
            index += 1
        case "--focus-key-point":
            options.action = .focusKeyPoint
            index += 1
        case "--focus-key-front-window":
            options.action = .focusKeyFrontWindow
            index += 1
        case "--focus-scroll-point":
            options.action = .focusScrollPoint
            index += 1
        case "--focus-scroll-front-window":
            options.action = .focusScrollFrontWindow
            index += 1
        case "--activate-app":
            options.action = .activateApp
            index += 1
        case "--sequence":
            let nextIndex = index + 1
            guard nextIndex < arguments.count else {
                throw GateLAXKeySenderError.invalidArgument(argument)
            }
            options.action = .sequence
            options.sequenceName = arguments[nextIndex]
            index += 2
        case "--click-identifier":
            let nextIndex = index + 1
            guard nextIndex < arguments.count else {
                throw GateLAXKeySenderError.invalidArgument(argument)
            }
            options.action = .clickFrontWindow
            options.targetIdentifier = arguments[nextIndex]
            index += 2
        case "--focus-key-identifier":
            let nextIndex = index + 1
            guard nextIndex < arguments.count else {
                throw GateLAXKeySenderError.invalidArgument(argument)
            }
            options.action = .focusKeyIdentifier
            options.targetIdentifier = arguments[nextIndex]
            index += 2
        case "--focus-scroll-identifier":
            let nextIndex = index + 1
            guard nextIndex < arguments.count else {
                throw GateLAXKeySenderError.invalidArgument(argument)
            }
            options.action = .focusScrollIdentifier
            options.targetIdentifier = arguments[nextIndex]
            index += 2
        case "--app-pid":
            let nextIndex = index + 1
            guard nextIndex < arguments.count,
                  let rawPID = Int32(arguments[nextIndex])
            else {
                throw GateLAXKeySenderError.invalidPID(arguments[safe: nextIndex] ?? argument)
            }
            options.appPID = rawPID
            index += 2
        case "--bundle-id":
            let nextIndex = index + 1
            guard nextIndex < arguments.count else {
                throw GateLAXKeySenderError.invalidArgument(argument)
            }
            options.bundleIdentifier = arguments[nextIndex]
            index += 2
        case "--key-code":
            let nextIndex = index + 1
            guard nextIndex < arguments.count, let keyCode = Int(arguments[nextIndex]) else {
                throw GateLAXKeySenderError.invalidArgument(argument)
            }
            options.keyCode = keyCode
            index += 2
        case "--scroll-lines":
            let nextIndex = index + 1
            guard nextIndex < arguments.count, let scrollLines = Int(arguments[nextIndex]) else {
                throw GateLAXKeySenderError.invalidArgument(argument)
            }
            options.scrollLines = scrollLines
            index += 2
        case "--point-x":
            let nextIndex = index + 1
            guard nextIndex < arguments.count, let pointX = Double(arguments[nextIndex]) else {
                throw GateLAXKeySenderError.invalidArgument(argument)
            }
            options.pointX = pointX
            index += 2
        case "--point-y":
            let nextIndex = index + 1
            guard nextIndex < arguments.count, let pointY = Double(arguments[nextIndex]) else {
                throw GateLAXKeySenderError.invalidArgument(argument)
            }
            options.pointY = pointY
            index += 2
        case "--x-frac":
            let nextIndex = index + 1
            guard nextIndex < arguments.count,
                  let xFraction = Double(arguments[nextIndex]),
                  (0.0...1.0).contains(xFraction)
            else {
                throw GateLAXKeySenderError.invalidFraction(arguments[safe: nextIndex] ?? argument)
            }
            options.xFraction = xFraction
            index += 2
        case "--y-frac":
            let nextIndex = index + 1
            guard nextIndex < arguments.count,
                  let yFraction = Double(arguments[nextIndex]),
                  (0.0...1.0).contains(yFraction)
            else {
                throw GateLAXKeySenderError.invalidFraction(arguments[safe: nextIndex] ?? argument)
            }
            options.yFraction = yFraction
            index += 2
        case "--modifier":
            let nextIndex = index + 1
            guard nextIndex < arguments.count else {
                throw GateLAXKeySenderError.invalidArgument(argument)
            }
            options.modifiers.append(arguments[nextIndex])
            index += 2
        default:
            throw GateLAXKeySenderError.invalidArgument(argument)
        }
    }

    return options
}

func eventFlags(for modifiers: [String]) throws -> CGEventFlags {
    var flags = CGEventFlags()

    for modifier in modifiers {
        switch modifier.lowercased() {
        case "shift":
            flags.insert(.maskShift)
        case "control", "ctrl":
            flags.insert(.maskControl)
        case "option", "alt":
            flags.insert(.maskAlternate)
        case "command", "cmd":
            flags.insert(.maskCommand)
        case "function", "fn":
            flags.insert(.maskSecondaryFn)
        default:
            throw GateLAXKeySenderError.unsupportedModifier(modifier)
        }
    }

    return flags
}

func normalizedModifiers(_ modifiers: [String]) throws -> [String] {
    var normalized: [String] = []
    var seen = Set<String>()

    for modifier in modifiers {
        let key: String
        switch modifier.lowercased() {
        case "shift":
            key = "shift"
        case "control", "ctrl":
            key = "control"
        case "option", "alt":
            key = "option"
        case "command", "cmd":
            key = "command"
        case "function", "fn":
            key = "function"
        default:
            throw GateLAXKeySenderError.unsupportedModifier(modifier)
        }
        if seen.insert(key).inserted {
            normalized.append(key)
        }
    }

    return normalized
}

func modifierKeyCode(for modifier: String) -> CGKeyCode {
    switch modifier {
    case "shift":
        return 56
    case "control":
        return 59
    case "option":
        return 58
    case "command":
        return 55
    case "function":
        return 63
    default:
        preconditionFailure("Unsupported normalized modifier: \(modifier)")
    }
}

func flag(forNormalizedModifier modifier: String) -> CGEventFlags {
    switch modifier {
    case "shift":
        return .maskShift
    case "control":
        return .maskControl
    case "option":
        return .maskAlternate
    case "command":
        return .maskCommand
    case "function":
        return .maskSecondaryFn
    default:
        preconditionFailure("Unsupported normalized modifier: \(modifier)")
    }
}

func actionName(for options: GateLAXKeySenderOptions) -> String {
    switch options.action {
    case .key:
        return "key"
    case .clickFrontWindow:
        return options.targetIdentifier == nil ? "click-front-window" : "click-identifier"
    case .activateApp:
        return "activate-app"
    case .sequence:
        return options.sequenceName.map { "sequence:\($0)" } ?? "sequence"
    case .focusKeyPoint:
        return "focus-key-point"
    case .focusKeyFrontWindow:
        return "focus-key-front-window"
    case .focusKeyIdentifier:
        return "focus-key-identifier"
    case .focusScrollPoint:
        return "focus-scroll-point"
    case .focusScrollFrontWindow:
        return "focus-scroll-front-window"
    case .focusScrollIdentifier:
        return "focus-scroll-identifier"
    }
}

func debugLog(_ message: @autoclosure () -> String) {
    guard ProcessInfo.processInfo.environment["GATE_L_AX_DEBUG"] == "1" else { return }
    FileHandle.standardError.write(Data(("[gate-l-ax] " + message() + "\n").utf8))
}

func resolveRunningApplication(
    appPID: pid_t?,
    bundleIdentifier: String?
) -> NSRunningApplication? {
    if let appPID {
        return NSRunningApplication(processIdentifier: appPID)
    }
    if let bundleIdentifier {
        return NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first
    }
    return nil
}

func activateRequestedApplication(
    appPID: pid_t?,
    bundleIdentifier: String?
) throws {
    guard appPID != nil || bundleIdentifier != nil else { return }

    let description = appPID.map(String.init) ?? bundleIdentifier ?? "unknown"
    guard let application = resolveRunningApplication(
        appPID: appPID,
        bundleIdentifier: bundleIdentifier
    ) else {
        throw GateLAXKeySenderError.targetApplicationUnavailable(description)
    }

    let activated = application.activate(options: [.activateAllWindows])
    guard activated else {
        throw GateLAXKeySenderError.targetApplicationActivationFailed(description)
    }

    usleep(120_000)
}

func postKeyStroke(
    source: CGEventSource,
    keyCode: Int,
    modifiers: [String]
) throws {
    let orderedModifiers = try normalizedModifiers(modifiers)
    let flags = try eventFlags(for: modifiers)

    guard let keyDown = CGEvent(
        keyboardEventSource: source,
        virtualKey: CGKeyCode(keyCode),
        keyDown: true
    ),
    let keyUp = CGEvent(
        keyboardEventSource: source,
        virtualKey: CGKeyCode(keyCode),
        keyDown: false
    ) else {
        throw GateLAXKeySenderError.eventCreationFailed
    }

    var heldFlags = CGEventFlags()
    for modifier in orderedModifiers {
        guard let modifierDown = CGEvent(
            keyboardEventSource: source,
            virtualKey: modifierKeyCode(for: modifier),
            keyDown: true
        ) else {
            throw GateLAXKeySenderError.eventCreationFailed
        }
        heldFlags.insert(flag(forNormalizedModifier: modifier))
        modifierDown.flags = heldFlags
        modifierDown.post(tap: .cghidEventTap)
        usleep(5_000)
    }

    keyDown.flags = flags
    keyUp.flags = flags
    keyDown.post(tap: .cghidEventTap)
    usleep(20_000)
    keyUp.post(tap: .cghidEventTap)

    for modifier in orderedModifiers.reversed() {
        heldFlags.remove(flag(forNormalizedModifier: modifier))
        guard let modifierUp = CGEvent(
            keyboardEventSource: source,
            virtualKey: modifierKeyCode(for: modifier),
            keyDown: false
        ) else {
            throw GateLAXKeySenderError.eventCreationFailed
        }
        modifierUp.flags = heldFlags
        modifierUp.post(tap: .cghidEventTap)
        usleep(5_000)
    }
}

func postFlaggedKeyStroke(
    source: CGEventSource,
    keyCode: Int,
    modifiers: [String]
) throws {
    let flags = try eventFlags(for: modifiers)

    guard let keyDown = CGEvent(
        keyboardEventSource: source,
        virtualKey: CGKeyCode(keyCode),
        keyDown: true
    ),
    let keyUp = CGEvent(
        keyboardEventSource: source,
        virtualKey: CGKeyCode(keyCode),
        keyDown: false
    ) else {
        throw GateLAXKeySenderError.eventCreationFailed
    }

    keyDown.flags = flags
    keyUp.flags = flags
    keyDown.post(tap: .cghidEventTap)
    usleep(20_000)
    keyUp.post(tap: .cghidEventTap)
}

func postClick(
    source: CGEventSource,
    point: CGPoint
) throws {
    guard let mouseDown = CGEvent(
        mouseEventSource: source,
        mouseType: .leftMouseDown,
        mouseCursorPosition: point,
        mouseButton: .left
    ),
    let mouseUp = CGEvent(
        mouseEventSource: source,
        mouseType: .leftMouseUp,
        mouseCursorPosition: point,
        mouseButton: .left
    ) else {
        throw GateLAXKeySenderError.eventCreationFailed
    }

    mouseDown.post(tap: .cghidEventTap)
    usleep(20_000)
    mouseUp.post(tap: .cghidEventTap)
}

func postSequence(
    named sequenceName: String,
    source: CGEventSource
) throws {
    switch sequenceName {
    case "tmux-next-pane":
        try postFlaggedKeyStroke(source: source, keyCode: 0, modifiers: ["control"])
        usleep(80_000)
        try postKeyStroke(source: source, keyCode: 31, modifiers: [])
    default:
        throw GateLAXKeySenderError.unsupportedSequence(sequenceName)
    }
}

func postScroll(
    source: CGEventSource,
    point: CGPoint,
    lines: Int
) throws {
    guard let event = CGEvent(
        scrollWheelEvent2Source: source,
        units: .line,
        wheelCount: 1,
        wheel1: Int32(lines),
        wheel2: 0,
        wheel3: 0
    ) else {
        throw GateLAXKeySenderError.eventCreationFailed
    }
    event.location = point
    event.post(tap: .cghidEventTap)
}

func requiredExplicitPoint(for options: GateLAXKeySenderOptions) throws -> CGPoint {
    guard let pointX = options.pointX, let pointY = options.pointY else {
        throw GateLAXKeySenderError.invalidArgument("--point-x/--point-y")
    }
    return CGPoint(x: pointX, y: pointY)
}

func frontWindowClickPoint(xFraction: Double, yFraction: Double) throws -> CGPoint {
    return try frontWindowClickPoint(
        xFraction: xFraction,
        yFraction: yFraction,
        targetIdentifier: nil,
        appPID: nil,
        bundleIdentifier: nil
    )
}

func frontWindowClickPoint(
    xFraction: Double,
    yFraction: Double,
    targetIdentifier: String?,
    appPID: pid_t?,
    bundleIdentifier: String?
) throws -> CGPoint {
    debugLog("resolve application pid=\(String(describing: appPID)) bundle=\(bundleIdentifier ?? "nil") target=\(targetIdentifier ?? "nil")")
    let application: AXUIElement
    if let appPID {
        application = AXUIElementCreateApplication(appPID)
    } else if let bundleIdentifier,
              let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first {
        application = AXUIElementCreateApplication(app.processIdentifier)
    } else if let frontmostApp = NSWorkspace.shared.frontmostApplication,
              frontmostApp.processIdentifier != pid_t(getpid()) {
        application = AXUIElementCreateApplication(frontmostApp.processIdentifier)
    } else {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedApplicationRef: CFTypeRef?
        let appResult = AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedApplicationAttribute as CFString,
            &focusedApplicationRef
        )
        guard appResult == .success, let focusedApplicationRef else {
            throw GateLAXKeySenderError.focusedApplicationUnavailable
        }
        application = unsafeBitCast(focusedApplicationRef, to: AXUIElement.self)
    }

    var focusedWindowRef: CFTypeRef?
    let windowResult = AXUIElementCopyAttributeValue(
        application,
        kAXFocusedWindowAttribute as CFString,
        &focusedWindowRef
    )
    debugLog("focused window result=\(windowResult.rawValue)")
    let focusedWindow = (windowResult == .success && focusedWindowRef != nil)
        ? unsafeBitCast(focusedWindowRef, to: AXUIElement.self)
        : nil

    guard focusedWindow != nil || targetIdentifier != nil else {
        throw GateLAXKeySenderError.focusedWindowUnavailable
    }

    func readCGPoint(_ element: AXUIElement, _ attribute: CFString, into value: inout CGPoint) -> Bool {
        var ref: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute, &ref)
        guard result == .success, let ref, CFGetTypeID(ref) == AXValueGetTypeID() else {
            return false
        }
        let axValue = unsafeBitCast(ref, to: AXValue.self)
        return AXValueGetValue(axValue, .cgPoint, &value)
    }

    func readCGSize(_ element: AXUIElement, _ attribute: CFString, into value: inout CGSize) -> Bool {
        var ref: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute, &ref)
        guard result == .success, let ref, CFGetTypeID(ref) == AXValueGetTypeID() else {
            return false
        }
        let axValue = unsafeBitCast(ref, to: AXValue.self)
        return AXValueGetValue(axValue, .cgSize, &value)
    }

    func readString(_ element: AXUIElement, _ attribute: CFString) -> String? {
        var ref: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute, &ref)
        guard result == .success, let ref else { return nil }
        if let string = ref as? String {
            return string
        }
        if let attributed = ref as? NSAttributedString {
            return attributed.string
        }
        return nil
    }

    func readElements(_ element: AXUIElement, _ attribute: CFString) -> [AXUIElement] {
        debugLog("readElements attr=\(attribute)")
        var ref: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute, &ref)
        guard result == .success, let ref else {
            debugLog("readElements attr=\(attribute) result=\(result.rawValue) empty")
            return []
        }

        guard let array = ref as? NSArray else {
            debugLog("readElements attr=\(attribute) non-array type")
            return []
        }

        debugLog("readElements attr=\(attribute) count=\(array.count)")

        return array.compactMap { child in
            debugLog("child class=\(String(describing: type(of: child)))")
            let childObject = child as AnyObject
            let childRef = childObject as CFTypeRef
            guard CFGetTypeID(childRef) == AXUIElementGetTypeID() else { return nil }
            return unsafeBitCast(childRef, to: AXUIElement.self)
        }
    }

    func rootWindows(for application: AXUIElement) -> [AXUIElement] {
        var windows = [AXUIElement]()
        if let focusedWindow {
            windows.append(focusedWindow)
        }
        let allWindows = readElements(application, kAXWindowsAttribute as CFString)
        for window in allWindows where windows.contains(where: { CFHash($0) == CFHash(window) }) == false {
            windows.append(window)
        }
        return windows
    }

    func findElement(
        matching identifier: String,
        in root: AXUIElement,
        visited: inout Set<CFHashCode>
    ) -> AXUIElement? {
        let key = CFHash(root)
        if visited.contains(key) { return nil }
        visited.insert(key)

        let searchableStrings = [
            readString(root, kAXIdentifierAttribute as CFString),
            readString(root, kAXTitleAttribute as CFString),
            readString(root, kAXDescriptionAttribute as CFString),
            readString(root, kAXValueAttribute as CFString)
        ].compactMap { $0 }
        if searchableStrings.isEmpty == false {
            debugLog("node strings=\(searchableStrings.joined(separator: " | "))")
        }

        if searchableStrings.contains(identifier) {
            return root
        }

        for child in readElements(root, kAXChildrenAttribute as CFString)
            + readElements(root, kAXVisibleChildrenAttribute as CFString)
            + readElements(root, kAXContentsAttribute as CFString)
        {
            if let match = findElement(matching: identifier, in: child, visited: &visited) {
                return match
            }
        }

        return nil
    }

    let targetElement: AXUIElement
    if let targetIdentifier {
        var visited = Set<CFHashCode>()
        debugLog("search target identifier=\(targetIdentifier)")
        var resolvedMatch: AXUIElement?
        for rootWindow in rootWindows(for: application) {
            if let match = findElement(matching: targetIdentifier, in: rootWindow, visited: &visited) {
                resolvedMatch = match
                break
            }
        }
        guard let match = resolvedMatch else {
            throw GateLAXKeySenderError.targetElementUnavailable(targetIdentifier)
        }
        targetElement = match
    } else {
        guard let focusedWindow else {
            throw GateLAXKeySenderError.focusedWindowUnavailable
        }
        targetElement = focusedWindow
    }

    let focusResult = AXUIElementSetAttributeValue(
        targetElement,
        kAXFocusedAttribute as CFString,
        kCFBooleanTrue
    )
    debugLog("set AXFocused result=\(focusResult.rawValue)")
    let pressResult = AXUIElementPerformAction(targetElement, kAXPressAction as CFString)
    debugLog("perform AXPress result=\(pressResult.rawValue)")

    var origin = CGPoint.zero
    var size = CGSize.zero
    guard readCGPoint(targetElement, kAXPositionAttribute as CFString, into: &origin),
          readCGSize(targetElement, kAXSizeAttribute as CFString, into: &size)
    else {
        throw GateLAXKeySenderError.focusedWindowFrameUnavailable
    }

    return CGPoint(
        x: origin.x + (size.width * xFraction),
        y: origin.y + (size.height * yFraction)
    )
}

func emit(_ result: GateLAXKeySenderResult, exitCode: Int32) -> Never {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try! encoder.encode(result)
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data([0x0a]))
    Foundation.exit(exitCode)
}

let binaryPath = CommandLine.arguments[0]
let bundlePath = Bundle.main.bundlePath
let pid = getpid()
var parsedOptions: GateLAXKeySenderOptions?

do {
    let options = try parseOptions(arguments: CommandLine.arguments)
    parsedOptions = options
    let trustOptions = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: options.prompt] as CFDictionary
    let trusted = AXIsProcessTrustedWithOptions(trustOptions)

    guard trusted else {
        emit(
            GateLAXKeySenderResult(
                binaryPath: binaryPath,
                bundlePath: bundlePath,
                pid: pid,
                trusted: false,
                prompted: options.prompt,
                sent: false,
                dryRun: options.dryRun,
                action: actionName(for: options),
                keyCode: options.keyCode,
                scrollLines: options.scrollLines == 0 ? nil : options.scrollLines,
                modifiers: options.modifiers,
                targetIdentifier: options.targetIdentifier,
                clickPoint: nil,
                error: "accessibility permission not granted"
            ),
            exitCode: 2
        )
    }

    if options.dryRun {
        emit(
            GateLAXKeySenderResult(
                binaryPath: binaryPath,
                bundlePath: bundlePath,
                pid: pid,
                trusted: true,
                prompted: options.prompt,
                sent: false,
                dryRun: true,
                action: actionName(for: options),
                keyCode: options.keyCode,
                scrollLines: options.scrollLines == 0 ? nil : options.scrollLines,
                modifiers: options.modifiers,
                targetIdentifier: options.targetIdentifier,
                clickPoint: nil,
                error: nil
            ),
            exitCode: 0
        )
    }

    guard let source = CGEventSource(stateID: .hidSystemState) else {
        throw GateLAXKeySenderError.eventSourceUnavailable
    }

    try activateRequestedApplication(
        appPID: options.appPID,
        bundleIdentifier: options.bundleIdentifier
    )

    let clickPoint: ClickPoint?

    switch options.action {
    case .key:
        try postKeyStroke(
            source: source,
            keyCode: options.keyCode,
            modifiers: options.modifiers
        )
        clickPoint = nil
    case .clickFrontWindow:
        let point = try frontWindowClickPoint(
            xFraction: options.xFraction,
            yFraction: options.yFraction,
            targetIdentifier: options.targetIdentifier,
            appPID: options.appPID,
            bundleIdentifier: options.bundleIdentifier
        )
        try postClick(source: source, point: point)
        clickPoint = ClickPoint(x: point.x, y: point.y)
    case .activateApp:
        guard options.appPID != nil || options.bundleIdentifier != nil else {
            throw GateLAXKeySenderError.targetApplicationUnavailable("missing --app-pid or --bundle-id")
        }
        clickPoint = nil
    case .sequence:
        guard let sequenceName = options.sequenceName else {
            throw GateLAXKeySenderError.invalidArgument("--sequence")
        }
        try postSequence(named: sequenceName, source: source)
        clickPoint = nil
    case .focusKeyPoint:
        let point = try requiredExplicitPoint(for: options)
        try postClick(source: source, point: point)
        usleep(120_000)
        try postKeyStroke(
            source: source,
            keyCode: options.keyCode,
            modifiers: options.modifiers
        )
        clickPoint = ClickPoint(x: point.x, y: point.y)
    case .focusKeyFrontWindow:
        let point = try frontWindowClickPoint(
            xFraction: options.xFraction,
            yFraction: options.yFraction,
            targetIdentifier: nil,
            appPID: options.appPID,
            bundleIdentifier: options.bundleIdentifier
        )
        try postClick(source: source, point: point)
        usleep(120_000)
        try postKeyStroke(
            source: source,
            keyCode: options.keyCode,
            modifiers: options.modifiers
        )
        clickPoint = ClickPoint(x: point.x, y: point.y)
    case .focusKeyIdentifier:
        guard let targetIdentifier = options.targetIdentifier, !targetIdentifier.isEmpty else {
            throw GateLAXKeySenderError.elementIdentifierMissing
        }
        let point = try frontWindowClickPoint(
            xFraction: options.xFraction,
            yFraction: options.yFraction,
            targetIdentifier: targetIdentifier,
            appPID: options.appPID,
            bundleIdentifier: options.bundleIdentifier
        )
        try postClick(source: source, point: point)
        usleep(120_000)
        try postKeyStroke(
            source: source,
            keyCode: options.keyCode,
            modifiers: options.modifiers
        )
        clickPoint = ClickPoint(x: point.x, y: point.y)
    case .focusScrollPoint:
        let point = try requiredExplicitPoint(for: options)
        try postClick(source: source, point: point)
        usleep(120_000)
        try postScroll(source: source, point: point, lines: options.scrollLines)
        clickPoint = ClickPoint(x: point.x, y: point.y)
    case .focusScrollFrontWindow:
        let point = try frontWindowClickPoint(
            xFraction: options.xFraction,
            yFraction: options.yFraction,
            targetIdentifier: nil,
            appPID: options.appPID,
            bundleIdentifier: options.bundleIdentifier
        )
        try postClick(source: source, point: point)
        usleep(120_000)
        try postScroll(source: source, point: point, lines: options.scrollLines)
        clickPoint = ClickPoint(x: point.x, y: point.y)
    case .focusScrollIdentifier:
        guard let targetIdentifier = options.targetIdentifier, !targetIdentifier.isEmpty else {
            throw GateLAXKeySenderError.elementIdentifierMissing
        }
        let point = try frontWindowClickPoint(
            xFraction: options.xFraction,
            yFraction: options.yFraction,
            targetIdentifier: targetIdentifier,
            appPID: options.appPID,
            bundleIdentifier: options.bundleIdentifier
        )
        try postClick(source: source, point: point)
        usleep(120_000)
        try postScroll(source: source, point: point, lines: options.scrollLines)
        clickPoint = ClickPoint(x: point.x, y: point.y)
    }

    emit(
        GateLAXKeySenderResult(
            binaryPath: binaryPath,
            bundlePath: bundlePath,
            pid: pid,
            trusted: true,
            prompted: options.prompt,
            sent: true,
            dryRun: false,
            action: actionName(for: options),
            keyCode: options.keyCode,
            scrollLines: options.scrollLines == 0 ? nil : options.scrollLines,
            modifiers: options.modifiers,
            targetIdentifier: options.targetIdentifier,
            clickPoint: clickPoint,
            error: nil
        ),
        exitCode: 0
    )
} catch let error as GateLAXKeySenderError {
        emit(
            GateLAXKeySenderResult(
                binaryPath: binaryPath,
                bundlePath: bundlePath,
                pid: pid,
                trusted: AXIsProcessTrusted(),
                prompted: false,
                sent: false,
                dryRun: false,
                action: parsedOptions.map(actionName(for:)) ?? "key",
                keyCode: parsedOptions?.keyCode ?? 125,
                scrollLines: (parsedOptions?.scrollLines == 0 ? nil : parsedOptions?.scrollLines),
                modifiers: parsedOptions?.modifiers ?? [],
                targetIdentifier: parsedOptions?.targetIdentifier,
                clickPoint: nil,
                error: error.description
            ),
            exitCode: 1
    )
} catch {
        emit(
            GateLAXKeySenderResult(
                binaryPath: binaryPath,
                bundlePath: bundlePath,
                pid: pid,
                trusted: AXIsProcessTrusted(),
                prompted: false,
                sent: false,
                dryRun: false,
                action: parsedOptions.map(actionName(for:)) ?? "key",
                keyCode: parsedOptions?.keyCode ?? 125,
                scrollLines: (parsedOptions?.scrollLines == 0 ? nil : parsedOptions?.scrollLines),
                modifiers: parsedOptions?.modifiers ?? [],
                targetIdentifier: parsedOptions?.targetIdentifier,
                clickPoint: nil,
                error: String(describing: error)
            ),
            exitCode: 1
    )
}

private extension Array where Element == String {
    subscript(safe index: Int) -> String? {
        guard indices.contains(index) else { return nil }
        return self[index]
    }
}
