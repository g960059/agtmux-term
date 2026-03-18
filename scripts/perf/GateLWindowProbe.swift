import ApplicationServices
import CryptoKit
import Foundation
import ImageIO

enum GateLWindowProbeError: Error, CustomStringConvertible {
    case invalidArgument(String)
    case invalidPID(String)
    case invalidWindowID(String)
    case invalidFraction(String)
    case missingAppPID
    case missingWindowID
    case windowNotFound(String)
    case imageCaptureFailed(String)
    case imageDataUnavailable(String)

    var description: String {
        switch self {
        case .invalidArgument(let value):
            return "invalid argument: \(value)"
        case .invalidPID(let value):
            return "invalid pid: \(value)"
        case .invalidWindowID(let value):
            return "invalid window id: \(value)"
        case .invalidFraction(let value):
            return "invalid fraction: \(value)"
        case .missingAppPID:
            return "missing --app-pid"
        case .missingWindowID:
            return "missing --window-id"
        case .windowNotFound(let value):
            return "window not found: \(value)"
        case .imageCaptureFailed(let value):
            return "window image capture failed: \(value)"
        case .imageDataUnavailable(let value):
            return "window image data unavailable: \(value)"
        }
    }
}

struct GateLWindowProbeResult: Encodable {
    let action: String
    let appPID: Int32?
    let windowID: UInt32?
    let hash: String?
    let bounds: WindowRect?
    let cropBounds: WindowRect?
    let error: String?
}

struct WindowRect: Encodable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double
}

struct GateLWindowProbeOptions {
    enum Action {
        case frontWindowID
        case hashWindow
    }

    var action: Action = .frontWindowID
    var appPID: pid_t?
    var windowID: CGWindowID?
    var xFraction = 0.0
    var yFraction = 0.0
    var widthFraction = 1.0
    var heightFraction = 1.0
}

func parseOptions(arguments: [String]) throws -> GateLWindowProbeOptions {
    var options = GateLWindowProbeOptions()
    var index = 1

    while index < arguments.count {
        let argument = arguments[index]
        switch argument {
        case "--front-window-id":
            options.action = .frontWindowID
            index += 1
        case "--hash":
            options.action = .hashWindow
            index += 1
        case "--app-pid":
            let nextIndex = index + 1
            guard nextIndex < arguments.count,
                  let rawPID = Int32(arguments[nextIndex]) else {
                throw GateLWindowProbeError.invalidPID(arguments[safe: nextIndex] ?? argument)
            }
            options.appPID = rawPID
            index += 2
        case "--window-id":
            let nextIndex = index + 1
            guard nextIndex < arguments.count,
                  let rawWindowID = UInt32(arguments[nextIndex]) else {
                throw GateLWindowProbeError.invalidWindowID(arguments[safe: nextIndex] ?? argument)
            }
            options.windowID = rawWindowID
            index += 2
        case "--x-frac":
            let nextIndex = index + 1
            guard nextIndex < arguments.count,
                  let value = Double(arguments[nextIndex]),
                  (0.0...1.0).contains(value) else {
                throw GateLWindowProbeError.invalidFraction(arguments[safe: nextIndex] ?? argument)
            }
            options.xFraction = value
            index += 2
        case "--y-frac":
            let nextIndex = index + 1
            guard nextIndex < arguments.count,
                  let value = Double(arguments[nextIndex]),
                  (0.0...1.0).contains(value) else {
                throw GateLWindowProbeError.invalidFraction(arguments[safe: nextIndex] ?? argument)
            }
            options.yFraction = value
            index += 2
        case "--width-frac":
            let nextIndex = index + 1
            guard nextIndex < arguments.count,
                  let value = Double(arguments[nextIndex]),
                  (0.0...1.0).contains(value) else {
                throw GateLWindowProbeError.invalidFraction(arguments[safe: nextIndex] ?? argument)
            }
            options.widthFraction = value
            index += 2
        case "--height-frac":
            let nextIndex = index + 1
            guard nextIndex < arguments.count,
                  let value = Double(arguments[nextIndex]),
                  (0.0...1.0).contains(value) else {
                throw GateLWindowProbeError.invalidFraction(arguments[safe: nextIndex] ?? argument)
            }
            options.heightFraction = value
            index += 2
        default:
            throw GateLWindowProbeError.invalidArgument(argument)
        }
    }

    if options.xFraction + options.widthFraction > 1.0 + 0.000_001 {
        throw GateLWindowProbeError.invalidFraction("x-frac + width-frac exceeds 1.0")
    }
    if options.yFraction + options.heightFraction > 1.0 + 0.000_001 {
        throw GateLWindowProbeError.invalidFraction("y-frac + height-frac exceeds 1.0")
    }

    return options
}

func windowRectPayload(_ rect: CGRect) -> WindowRect {
    WindowRect(
        x: rect.origin.x,
        y: rect.origin.y,
        width: rect.size.width,
        height: rect.size.height
    )
}

func cgRect(from dictionary: NSDictionary) -> CGRect? {
    guard let rawX = dictionary["X"] as? NSNumber,
          let rawY = dictionary["Y"] as? NSNumber,
          let rawWidth = dictionary["Width"] as? NSNumber,
          let rawHeight = dictionary["Height"] as? NSNumber else {
        return nil
    }

    return CGRect(
        x: rawX.doubleValue,
        y: rawY.doubleValue,
        width: rawWidth.doubleValue,
        height: rawHeight.doubleValue
    )
}

func windowInfo(windowID: CGWindowID) throws -> [String: Any] {
    guard let infoList = CGWindowListCopyWindowInfo([.optionIncludingWindow], windowID) as? [[String: Any]],
          let info = infoList.first else {
        throw GateLWindowProbeError.windowNotFound(String(windowID))
    }
    return info
}

func frontWindowInfo(appPID: pid_t) throws -> [String: Any] {
    guard let infoList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
        throw GateLWindowProbeError.windowNotFound("app pid \(appPID)")
    }

    let match = infoList.first { info in
        guard let ownerPID = info[kCGWindowOwnerPID as String] as? NSNumber,
              ownerPID.int32Value == appPID else {
            return false
        }
        let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
        let alpha = (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1.0
        guard layer == 0, alpha > 0 else { return false }
        guard let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
              let bounds = cgRect(from: boundsDict) else {
            return false
        }
        return bounds.width >= 200 && bounds.height >= 120
    }

    guard let match else {
        throw GateLWindowProbeError.windowNotFound("front window for app pid \(appPID)")
    }
    return match
}

func cropRect(bounds: CGRect, options: GateLWindowProbeOptions) -> CGRect {
    CGRect(
        x: bounds.origin.x + (bounds.width * options.xFraction),
        y: bounds.origin.y + (bounds.height * options.yFraction),
        width: bounds.width * options.widthFraction,
        height: bounds.height * options.heightFraction
    ).integral
}

func hashForWindow(windowID: CGWindowID, options: GateLWindowProbeOptions) throws -> (String, CGRect, CGRect) {
    let info = try windowInfo(windowID: windowID)
    guard let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
          let bounds = cgRect(from: boundsDict) else {
        throw GateLWindowProbeError.windowNotFound("bounds for window \(windowID)")
    }

    let tempDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
    let tempURL = tempDir.appendingPathComponent("gate-l-window-\(windowID)-\(UUID().uuidString).png")
    defer { try? FileManager.default.removeItem(at: tempURL) }

    let targetRect = cropRect(bounds: bounds, options: options)
    guard targetRect.width > 0, targetRect.height > 0 else {
        throw GateLWindowProbeError.invalidFraction("crop produced an empty rect")
    }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    let rectArgument = String(
        format: "-R%.0f,%.0f,%.0f,%.0f",
        targetRect.origin.x,
        targetRect.origin.y,
        targetRect.size.width,
        targetRect.size.height
    )
    process.arguments = ["-x", rectArgument, tempURL.path]

    do {
        try process.run()
    } catch {
        throw GateLWindowProbeError.imageCaptureFailed("window \(windowID)")
    }
    process.waitUntilExit()

    guard process.terminationStatus == 0 else {
        throw GateLWindowProbeError.imageCaptureFailed("window \(windowID)")
    }

    guard let fileData = try? Data(contentsOf: tempURL),
          let imageSource = CGImageSourceCreateWithData(fileData as CFData, nil),
          let image = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
        throw GateLWindowProbeError.imageDataUnavailable("window \(windowID)")
    }

    guard let provider = image.dataProvider,
          let providerData = provider.data else {
        throw GateLWindowProbeError.imageDataUnavailable("window \(windowID)")
    }

    let data = providerData as Data
    let digest = SHA256.hash(data: data)
    let hash = digest.map { String(format: "%02x", $0) }.joined()
    return (hash, bounds, targetRect)
}

func emit(_ result: GateLWindowProbeResult, exitCode: Int32) -> Never {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try! encoder.encode(result)
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
    Foundation.exit(exitCode)
}

var parsedOptions: GateLWindowProbeOptions?

do {
    let options = try parseOptions(arguments: CommandLine.arguments)
    parsedOptions = options

    switch options.action {
    case .frontWindowID:
        guard let appPID = options.appPID else {
            throw GateLWindowProbeError.missingAppPID
        }
        let info = try frontWindowInfo(appPID: appPID)
        guard let rawWindowID = info[kCGWindowNumber as String] as? NSNumber,
              let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
              let bounds = cgRect(from: boundsDict) else {
            throw GateLWindowProbeError.windowNotFound("front window for app pid \(appPID)")
        }
        emit(
            GateLWindowProbeResult(
                action: "front-window-id",
                appPID: appPID,
                windowID: rawWindowID.uint32Value,
                hash: nil,
                bounds: windowRectPayload(bounds),
                cropBounds: nil,
                error: nil
            ),
            exitCode: 0
        )
    case .hashWindow:
        guard let windowID = options.windowID else {
            throw GateLWindowProbeError.missingWindowID
        }
        let (hash, bounds, croppedBounds) = try hashForWindow(windowID: windowID, options: options)
        emit(
            GateLWindowProbeResult(
                action: "hash",
                appPID: options.appPID,
                windowID: windowID,
                hash: hash,
                bounds: windowRectPayload(bounds),
                cropBounds: windowRectPayload(croppedBounds),
                error: nil
            ),
            exitCode: 0
        )
    }
} catch let error as GateLWindowProbeError {
    emit(
        GateLWindowProbeResult(
            action: parsedOptions?.action == .hashWindow ? "hash" : "front-window-id",
            appPID: parsedOptions?.appPID,
            windowID: parsedOptions?.windowID,
            hash: nil,
            bounds: nil,
            cropBounds: nil,
            error: error.description
        ),
        exitCode: 1
    )
} catch {
    emit(
        GateLWindowProbeResult(
            action: parsedOptions?.action == .hashWindow ? "hash" : "front-window-id",
            appPID: parsedOptions?.appPID,
            windowID: parsedOptions?.windowID,
            hash: nil,
            bounds: nil,
            cropBounds: nil,
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
