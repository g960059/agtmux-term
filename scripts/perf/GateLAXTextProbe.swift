import AppKit
import ApplicationServices
import Foundation

enum GateLAXTextProbeError: Error, CustomStringConvertible {
    case invalidArgument(String)
    case invalidPID(String)
    case targetApplicationUnavailable(String)
    case focusedApplicationUnavailable
    case focusedWindowUnavailable
    case targetElementUnavailable(String)

    var description: String {
        switch self {
        case .invalidArgument(let value):
            return "invalid argument: \(value)"
        case .invalidPID(let value):
            return "invalid pid: \(value)"
        case .targetApplicationUnavailable(let value):
            return "failed to resolve target application: \(value)"
        case .focusedApplicationUnavailable:
            return "failed to resolve focused application"
        case .focusedWindowUnavailable:
            return "failed to resolve focused window"
        case .targetElementUnavailable(let value):
            return "failed to resolve target element: \(value)"
        }
    }
}

struct GateLAXTextProbeSample: Encodable {
    let sampleIndex: Int
    let elapsedMs: Double
    let value: String
    let lineCount: Int
}

struct GateLAXTextProbeResult: Encodable {
    let binaryPath: String
    let bundlePath: String
    let pid: Int32
    let trusted: Bool
    let appPID: Int32?
    let bundleIdentifier: String?
    let targetIdentifier: String?
    let targetRole: String
    let sampleCount: Int
    let sampleIntervalMs: Int
    let value: String?
    let lineCount: Int?
    let samples: [GateLAXTextProbeSample]
    let error: String?
}

struct GateLAXTextProbeOptions {
    var appPID: pid_t?
    var bundleIdentifier: String?
    var targetIdentifier: String?
    var targetRole: String = kAXTextAreaRole as String
    var sampleCount = 1
    var sampleIntervalMs = 0
}

func parseOptions(arguments: [String]) throws -> GateLAXTextProbeOptions {
    var options = GateLAXTextProbeOptions()
    var index = 1

    while index < arguments.count {
        let argument = arguments[index]
        switch argument {
        case "--app-pid":
            let nextIndex = index + 1
            guard nextIndex < arguments.count,
                  let rawPID = Int32(arguments[nextIndex]) else {
                throw GateLAXTextProbeError.invalidPID(arguments[safe: nextIndex] ?? argument)
            }
            options.appPID = rawPID
            index += 2
        case "--bundle-id":
            let nextIndex = index + 1
            guard nextIndex < arguments.count else {
                throw GateLAXTextProbeError.invalidArgument(argument)
            }
            options.bundleIdentifier = arguments[nextIndex]
            index += 2
        case "--identifier":
            let nextIndex = index + 1
            guard nextIndex < arguments.count else {
                throw GateLAXTextProbeError.invalidArgument(argument)
            }
            options.targetIdentifier = arguments[nextIndex]
            index += 2
        case "--role":
            let nextIndex = index + 1
            guard nextIndex < arguments.count else {
                throw GateLAXTextProbeError.invalidArgument(argument)
            }
            options.targetRole = arguments[nextIndex]
            index += 2
        case "--sample-count":
            let nextIndex = index + 1
            guard nextIndex < arguments.count,
                  let sampleCount = Int(arguments[nextIndex]),
                  sampleCount > 0 else {
                throw GateLAXTextProbeError.invalidArgument(argument)
            }
            options.sampleCount = sampleCount
            index += 2
        case "--sample-interval-ms":
            let nextIndex = index + 1
            guard nextIndex < arguments.count,
                  let sampleIntervalMs = Int(arguments[nextIndex]),
                  sampleIntervalMs >= 0 else {
                throw GateLAXTextProbeError.invalidArgument(argument)
            }
            options.sampleIntervalMs = sampleIntervalMs
            index += 2
        default:
            throw GateLAXTextProbeError.invalidArgument(argument)
        }
    }

    return options
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

func readVisibleRangeString(_ element: AXUIElement) -> String? {
    var rangeRef: CFTypeRef?
    let rangeResult = AXUIElementCopyAttributeValue(
        element,
        kAXVisibleCharacterRangeAttribute as CFString,
        &rangeRef
    )
    guard rangeResult == .success,
          let rangeRef,
          CFGetTypeID(rangeRef) == AXValueGetTypeID()
    else {
        return nil
    }

    let axRangeValue = unsafeBitCast(rangeRef, to: AXValue.self)
    var visibleRange = CFRange()
    guard AXValueGetValue(axRangeValue, .cfRange, &visibleRange) else {
        return nil
    }

    var parameterizedRef: CFTypeRef?
    let parameterizedResult = AXUIElementCopyParameterizedAttributeValue(
        element,
        kAXStringForRangeParameterizedAttribute as CFString,
        axRangeValue,
        &parameterizedRef
    )
    guard parameterizedResult == .success, let parameterizedRef else {
        return nil
    }

    if let string = parameterizedRef as? String {
        return string
    }
    if let attributed = parameterizedRef as? NSAttributedString {
        return attributed.string
    }
    return nil
}

func readElements(_ element: AXUIElement, _ attribute: CFString) -> [AXUIElement] {
    var ref: CFTypeRef?
    let result = AXUIElementCopyAttributeValue(element, attribute, &ref)
    guard result == .success, let ref, let array = ref as? NSArray else { return [] }
    return array.compactMap { child in
        let childObject = child as AnyObject
        let childRef = childObject as CFTypeRef
        guard CFGetTypeID(childRef) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(childRef, to: AXUIElement.self)
    }
}

func rootWindows(for application: AXUIElement) -> [AXUIElement] {
    var windows = [AXUIElement]()

    var focusedWindowRef: CFTypeRef?
    if AXUIElementCopyAttributeValue(
        application,
        kAXFocusedWindowAttribute as CFString,
        &focusedWindowRef
    ) == .success, let focusedWindowRef {
        windows.append(unsafeBitCast(focusedWindowRef, to: AXUIElement.self))
    }

    let allWindows = readElements(application, kAXWindowsAttribute as CFString)
    for window in allWindows where windows.contains(where: { CFHash($0) == CFHash(window) }) == false {
        windows.append(window)
    }

    return windows
}

func focusedUIElement(for application: AXUIElement) -> AXUIElement? {
    var focusedElementRef: CFTypeRef?
    let result = AXUIElementCopyAttributeValue(
        application,
        kAXFocusedUIElementAttribute as CFString,
        &focusedElementRef
    )
    guard result == .success, let focusedElementRef else { return nil }
    return unsafeBitCast(focusedElementRef, to: AXUIElement.self)
}

func resolveApplication(appPID: pid_t?, bundleIdentifier: String?) throws -> AXUIElement {
    if let appPID {
        return AXUIElementCreateApplication(appPID)
    }

    if let bundleIdentifier,
       let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first {
        return AXUIElementCreateApplication(app.processIdentifier)
    }

    if let frontmostApp = NSWorkspace.shared.frontmostApplication,
       frontmostApp.processIdentifier != pid_t(getpid()) {
        return AXUIElementCreateApplication(frontmostApp.processIdentifier)
    }

    let systemWide = AXUIElementCreateSystemWide()
    var focusedApplicationRef: CFTypeRef?
    let appResult = AXUIElementCopyAttributeValue(
        systemWide,
        kAXFocusedApplicationAttribute as CFString,
        &focusedApplicationRef
    )
    guard appResult == .success, let focusedApplicationRef else {
        throw GateLAXTextProbeError.focusedApplicationUnavailable
    }
    return unsafeBitCast(focusedApplicationRef, to: AXUIElement.self)
}

func findFirstElement(
    in root: AXUIElement,
    matchingIdentifier identifier: String?,
    role targetRole: String,
    visited: inout Set<CFHashCode>
) -> AXUIElement? {
    let key = CFHash(root)
    if visited.contains(key) { return nil }
    visited.insert(key)

    let role = readString(root, kAXRoleAttribute as CFString)
    let searchableStrings = [
        readString(root, kAXIdentifierAttribute as CFString),
        readString(root, kAXTitleAttribute as CFString),
        readString(root, kAXDescriptionAttribute as CFString),
        readString(root, kAXValueAttribute as CFString)
    ].compactMap { $0 }
    let children = readElements(root, kAXChildrenAttribute as CFString)
        + readElements(root, kAXVisibleChildrenAttribute as CFString)
        + readElements(root, kAXContentsAttribute as CFString)

    if let identifier {
        if searchableStrings.contains(identifier) {
            if role == targetRole {
                return root
            }
            var subtreeVisited = visited
            for child in children {
                if let roleMatch = findFirstElement(
                    in: child,
                    matchingIdentifier: nil,
                    role: targetRole,
                    visited: &subtreeVisited
                ) {
                    return roleMatch
                }
            }
            return root
        }
    } else if role == targetRole {
        return root
    }

    for child in children {
        if let match = findFirstElement(
            in: child,
            matchingIdentifier: identifier,
            role: targetRole,
            visited: &visited
        ) {
            return match
        }
    }

    return nil
}

func resolveTargetElement(options: GateLAXTextProbeOptions) throws -> AXUIElement {
    let application = try resolveApplication(appPID: options.appPID, bundleIdentifier: options.bundleIdentifier)
    var visited = Set<CFHashCode>()

    if options.targetIdentifier == nil, let focusedElement = focusedUIElement(for: application) {
        if let match = findFirstElement(
            in: focusedElement,
            matchingIdentifier: nil,
            role: options.targetRole,
            visited: &visited
        ) {
            return match
        }
    }

    let windows = rootWindows(for: application)
    guard windows.isEmpty == false else {
        throw GateLAXTextProbeError.focusedWindowUnavailable
    }

    for window in windows {
        if let match = findFirstElement(
            in: window,
            matchingIdentifier: options.targetIdentifier,
            role: options.targetRole,
            visited: &visited
        ) {
            return match
        }
    }

    throw GateLAXTextProbeError.targetElementUnavailable(options.targetIdentifier ?? options.targetRole)
}

func lineCount(for value: String) -> Int {
    value.isEmpty ? 0 : value.split(separator: "\n", omittingEmptySubsequences: false).count
}

func captureSamples(
    element: AXUIElement,
    sampleCount: Int,
    sampleIntervalMs: Int
) throws -> [GateLAXTextProbeSample] {
    let startUptime = ProcessInfo.processInfo.systemUptime
    var samples: [GateLAXTextProbeSample] = []
    samples.reserveCapacity(sampleCount)

    for sampleIndex in 0..<sampleCount {
        let value = readVisibleRangeString(element)
            ?? readString(element, kAXValueAttribute as CFString)
            ?? ""
        let elapsedMs = (ProcessInfo.processInfo.systemUptime - startUptime) * 1000.0
        samples.append(
            GateLAXTextProbeSample(
                sampleIndex: sampleIndex,
                elapsedMs: elapsedMs,
                value: value,
                lineCount: lineCount(for: value)
            )
        )
        if sampleIndex < sampleCount - 1, sampleIntervalMs > 0 {
            usleep(useconds_t(sampleIntervalMs * 1000))
        }
    }

    return samples
}

func emit(_ result: GateLAXTextProbeResult, exitCode: Int32) -> Never {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try! encoder.encode(result)
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data([0x0a]))
    Foundation.exit(exitCode)
}

@main
enum GateLAXTextProbeMain {
    static func main() {
        let binaryPath = CommandLine.arguments[0]
        let bundlePath = Bundle.main.bundlePath
        let pid = getpid()

        do {
            let options = try parseOptions(arguments: CommandLine.arguments)
            let trustOptions = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false] as CFDictionary
            let trusted = AXIsProcessTrustedWithOptions(trustOptions)
            guard trusted else {
                emit(
                    GateLAXTextProbeResult(
                        binaryPath: binaryPath,
                        bundlePath: bundlePath,
                        pid: pid,
                        trusted: false,
                        appPID: options.appPID,
                        bundleIdentifier: options.bundleIdentifier,
                        targetIdentifier: options.targetIdentifier,
                        targetRole: options.targetRole,
                        sampleCount: options.sampleCount,
                        sampleIntervalMs: options.sampleIntervalMs,
                        value: nil,
                        lineCount: nil,
                        samples: [],
                        error: nil
                    ),
                    exitCode: 0
                )
            }

            let element = try resolveTargetElement(options: options)
            let samples = try captureSamples(
                element: element,
                sampleCount: options.sampleCount,
                sampleIntervalMs: options.sampleIntervalMs
            )
            let last = samples.last
            emit(
                GateLAXTextProbeResult(
                    binaryPath: binaryPath,
                    bundlePath: bundlePath,
                    pid: pid,
                    trusted: trusted,
                    appPID: options.appPID,
                    bundleIdentifier: options.bundleIdentifier,
                    targetIdentifier: options.targetIdentifier,
                    targetRole: options.targetRole,
                    sampleCount: options.sampleCount,
                    sampleIntervalMs: options.sampleIntervalMs,
                    value: last?.value,
                    lineCount: last?.lineCount,
                    samples: samples,
                    error: nil
                ),
                exitCode: 0
            )
        } catch {
            let options = try? parseOptions(arguments: CommandLine.arguments)
            emit(
                GateLAXTextProbeResult(
                    binaryPath: binaryPath,
                    bundlePath: bundlePath,
                    pid: pid,
                    trusted: AXIsProcessTrusted(),
                    appPID: options?.appPID,
                    bundleIdentifier: options?.bundleIdentifier,
                    targetIdentifier: options?.targetIdentifier,
                    targetRole: options?.targetRole ?? (kAXTextAreaRole as String),
                    sampleCount: options?.sampleCount ?? 1,
                    sampleIntervalMs: options?.sampleIntervalMs ?? 0,
                    value: nil,
                    lineCount: nil,
                    samples: [],
                    error: (error as? GateLAXTextProbeError)?.description ?? error.localizedDescription
                ),
                exitCode: 1
            )
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
