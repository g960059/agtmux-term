import Foundation

/// Shared constants for agtmux XPC service integration.
public enum AgtmuxDaemonXPC {
    /// XPC service bundle identifier used by `NSXPCConnection(serviceName:)`.
    public static let serviceName = "local.agtmux.term.daemonservice"
}

/// XPC contract exposed by the bundled daemon service.
///
/// Wire format:
/// - `fetchSnapshot`: UTF-8 JSON encoded `AgtmuxSnapshot` (ISO8601 dates)
/// - errors: human-readable strings
@objc public protocol AgtmuxDaemonServiceXPCProtocol {
    func startManagedDaemon(_ reply: @escaping (Bool, NSString?) -> Void)
    func fetchSnapshot(_ reply: @escaping (NSData?, NSString?) -> Void)
    func stopManagedDaemon(_ reply: @escaping () -> Void)
}
