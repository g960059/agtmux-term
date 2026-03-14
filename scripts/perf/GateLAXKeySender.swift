import ApplicationServices
import Foundation

enum GateLAXKeySenderError: Error, CustomStringConvertible {
    case invalidArgument(String)
    case unsupportedModifier(String)
    case eventSourceUnavailable
    case eventCreationFailed

    var description: String {
        switch self {
        case .invalidArgument(let value):
            return "invalid argument: \(value)"
        case .unsupportedModifier(let value):
            return "unsupported modifier: \(value)"
        case .eventSourceUnavailable:
            return "failed to create CGEventSource"
        case .eventCreationFailed:
            return "failed to create keyboard event"
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
    let keyCode: Int
    let modifiers: [String]
    let error: String?
}

struct GateLAXKeySenderOptions {
    var prompt = false
    var dryRun = false
    var keyCode = 125
    var modifiers: [String] = []
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
        case "--key-code":
            let nextIndex = index + 1
            guard nextIndex < arguments.count, let keyCode = Int(arguments[nextIndex]) else {
                throw GateLAXKeySenderError.invalidArgument(argument)
            }
            options.keyCode = keyCode
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

do {
    let options = try parseOptions(arguments: CommandLine.arguments)
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
                keyCode: options.keyCode,
                modifiers: options.modifiers,
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
                keyCode: options.keyCode,
                modifiers: options.modifiers,
                error: nil
            ),
            exitCode: 0
        )
    }

    let flags = try eventFlags(for: options.modifiers)
    guard let source = CGEventSource(stateID: .hidSystemState) else {
        throw GateLAXKeySenderError.eventSourceUnavailable
    }

    guard let keyDown = CGEvent(
        keyboardEventSource: source,
        virtualKey: CGKeyCode(options.keyCode),
        keyDown: true
    ),
    let keyUp = CGEvent(
        keyboardEventSource: source,
        virtualKey: CGKeyCode(options.keyCode),
        keyDown: false
    ) else {
        throw GateLAXKeySenderError.eventCreationFailed
    }

    keyDown.flags = flags
    keyUp.flags = flags
    keyDown.post(tap: .cghidEventTap)
    usleep(20_000)
    keyUp.post(tap: .cghidEventTap)

    emit(
        GateLAXKeySenderResult(
            binaryPath: binaryPath,
            bundlePath: bundlePath,
            pid: pid,
            trusted: true,
            prompted: options.prompt,
            sent: true,
            dryRun: false,
            keyCode: options.keyCode,
            modifiers: options.modifiers,
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
            keyCode: 125,
            modifiers: [],
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
            keyCode: 125,
            modifiers: [],
            error: String(describing: error)
        ),
        exitCode: 1
    )
}
