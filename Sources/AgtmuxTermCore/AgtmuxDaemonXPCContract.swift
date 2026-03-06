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
/// - `fetchUIBootstrapV2`: UTF-8 JSON encoded `AgtmuxSyncV2Bootstrap` (ISO8601 dates)
/// - `fetchUIChangesV2`: UTF-8 JSON encoded `AgtmuxSyncV2ChangesResponse` (ISO8601 dates)
/// - `fetchUIHealthV1`: UTF-8 JSON encoded `AgtmuxUIHealthV1` (ISO8601 dates)
/// - errors: human-readable strings
@objc public protocol AgtmuxDaemonServiceXPCProtocol {
    func startManagedDaemon(_ reply: @escaping (Bool, NSString?) -> Void)
    func fetchSnapshot(_ reply: @escaping (NSData?, NSString?) -> Void)
    func fetchUIBootstrapV2(_ reply: @escaping (NSData?, NSString?) -> Void)
    func fetchUIChangesV2(_ limit: NSNumber, reply: @escaping (NSData?, NSString?) -> Void)
    func fetchUIHealthV1(_ reply: @escaping (NSData?, NSString?) -> Void)
    func resetUIChangesV2(_ reply: @escaping () -> Void)
    func stopManagedDaemon(_ reply: @escaping () -> Void)
}
