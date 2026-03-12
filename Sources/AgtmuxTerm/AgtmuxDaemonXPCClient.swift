import Foundation
import AgtmuxTermCore

enum XPCClientError: Error {
    case unavailable
    case proxyUnavailable
    case remote(String)
    case timeout(String)
    case decode(String)
}

#if AGTMUX_STANDALONE_XPCCLIENT
private protocol AgtmuxDaemonXPCClientMetadataConformance {}
#else
private typealias AgtmuxDaemonXPCClientMetadataConformance = ProductLocalMetadataClient
#endif

actor AgtmuxDaemonXPCClient: AgtmuxDaemonXPCClientMetadataConformance {
    typealias ProxyProvider = (@escaping (Error) -> Void) -> (any AgtmuxDaemonServiceXPCProtocol)?

    private let serviceName: String
    private let listenerEndpointOverride: NSXPCListenerEndpoint?
    private let proxyProviderOverride: ProxyProvider?
    private var connection: NSXPCConnection?
    // Performance hint only. Service-side fetchSnapshot always re-checks startIfNeeded.
    private var daemonStartedInSession = false

    init(
        serviceName: String = AgtmuxDaemonXPC.serviceName,
        listenerEndpointOverride: NSXPCListenerEndpoint? = nil,
        proxyProviderOverride: ProxyProvider? = nil
    ) {
        self.serviceName = serviceName
        self.listenerEndpointOverride = listenerEndpointOverride
        self.proxyProviderOverride = proxyProviderOverride
    }

    func startManagedDaemonIfNeeded() async throws {
        if daemonStartedInSession { return }

        let started: Bool = try await invoke(timeout: 5.0, operation: "startManagedDaemon") { proxy, done in
            proxy.startManagedDaemon { ok, errorText in
                if let errorText {
                    done(.failure(XPCClientError.remote(errorText as String)))
                    return
                }
                done(.success(ok))
            }
        }

        guard started else { throw XPCClientError.remote("service returned start=false") }
        daemonStartedInSession = true
    }

    func stopManagedDaemonIfOwned() async {
        _ = try? await invoke(timeout: 2.0, operation: "stopManagedDaemon") { proxy, done in
            proxy.stopManagedDaemon {
                done(.success(()))
            }
        }
        daemonStartedInSession = false
    }

    func invalidate() {
        connection?.invalidate()
        connection = nil
        daemonStartedInSession = false
    }

    func fetchSnapshot() async throws -> AgtmuxSnapshot {
        try await startManagedDaemonIfNeeded()

        let payload: Data = try await invoke(timeout: 5.0, operation: "fetchSnapshot") { proxy, done in
            proxy.fetchSnapshot { data, errorText in
                if let errorText {
                    done(.failure(XPCClientError.remote(errorText as String)))
                    return
                }
                guard let data else {
                    done(.failure(XPCClientError.remote("no snapshot payload")))
                    return
                }
                done(.success(data as Data))
            }
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(AgtmuxSnapshot.self, from: payload)
        } catch {
            throw XPCClientError.decode(error.localizedDescription)
        }
    }

    func fetchUIBootstrapV3() async throws -> AgtmuxSyncV3Bootstrap {
        try await startManagedDaemonIfNeeded()

        let payload: Data = try await invoke(timeout: 5.0, operation: "fetchUIBootstrapV3") { proxy, done in
            proxy.fetchUIBootstrapV3 { data, errorText in
                if let errorText {
                    done(.failure(XPCClientError.remote(errorText as String)))
                    return
                }
                guard let data else {
                    done(.failure(XPCClientError.remote("no bootstrap v3 payload")))
                    return
                }
                done(.success(data as Data))
            }
        }

        return try decode(AgtmuxSyncV3Bootstrap.self, from: payload)
    }

    func fetchUIChangesV3(limit: Int = 256) async throws -> AgtmuxSyncV3ChangesResponse {
        try await startManagedDaemonIfNeeded()

        let payload: Data = try await invoke(timeout: 5.0, operation: "fetchUIChangesV3") { proxy, done in
            proxy.fetchUIChangesV3(NSNumber(value: limit)) { data, errorText in
                if let errorText {
                    done(.failure(XPCClientError.remote(errorText as String)))
                    return
                }
                guard let data else {
                    done(.failure(XPCClientError.remote("no changes v3 payload")))
                    return
                }
                done(.success(data as Data))
            }
        }

        return try decode(AgtmuxSyncV3ChangesResponse.self, from: payload)
    }

    func fetchUIHealthV1() async throws -> AgtmuxUIHealthV1 {
        try await startManagedDaemonIfNeeded()

        let payload: Data = try await invoke(timeout: 5.0, operation: "fetchUIHealthV1") { proxy, done in
            proxy.fetchUIHealthV1 { data, errorText in
                if let errorText {
                    done(.failure(XPCClientError.remote(errorText as String)))
                    return
                }
                guard let data else {
                    done(.failure(XPCClientError.remote("no ui.health.v1 payload")))
                    return
                }
                done(.success(data as Data))
            }
        }

        return try decode(AgtmuxUIHealthV1.self, from: payload)
    }

    func waitForUIChangesV1(timeoutMs: UInt64 = 3000) async throws -> AgtmuxSyncV3ChangesResponse {
        try await startManagedDaemonIfNeeded()

        let payload: Data = try await invoke(timeout: Double(timeoutMs) / 1000.0 + 2.0, operation: "waitForUIChangesV1") { proxy, done in
            proxy.waitForUIChangesV1(NSNumber(value: timeoutMs)) { data, errorText in
                if let errorText {
                    done(.failure(XPCClientError.remote(errorText as String)))
                    return
                }
                guard let data else {
                    done(.failure(XPCClientError.remote("no wait_for_changes payload")))
                    return
                }
                done(.success(data as Data))
            }
        }

        return try decode(AgtmuxSyncV3ChangesResponse.self, from: payload)
    }

    func resetUIChangesV3() async {
        _ = try? await invoke(timeout: 2.0, operation: "resetUIChangesV3") { proxy, done in
            proxy.resetUIChangesV3 {
                done(.success(()))
            }
        }
    }

    // MARK: - Internal

    private func getConnection() -> NSXPCConnection {
        if let connection { return connection }

        let newConnection: NSXPCConnection
        if let listenerEndpointOverride {
            newConnection = NSXPCConnection(listenerEndpoint: listenerEndpointOverride)
        } else {
            newConnection = NSXPCConnection(serviceName: serviceName)
        }
        newConnection.remoteObjectInterface = NSXPCInterface(with: AgtmuxDaemonServiceXPCProtocol.self)

        newConnection.interruptionHandler = { [weak self] in
            Task { await self?.handleConnectionInvalidation() }
        }
        newConnection.invalidationHandler = { [weak self] in
            Task { await self?.handleConnectionInvalidation() }
        }

        newConnection.resume()
        connection = newConnection
        return newConnection
    }

    private func handleConnectionInvalidation() {
        connection = nil
        daemonStartedInSession = false
    }

    private func decode<T: Decodable>(_ type: T.Type, from payload: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(T.self, from: payload)
        } catch {
            throw XPCClientError.decode(error.localizedDescription)
        }
    }

    private func invoke<T>(
        timeout: TimeInterval,
        operation: String,
        _ call: @escaping (AgtmuxDaemonServiceXPCProtocol, @escaping (Result<T, Error>) -> Void) -> Void
    ) async throws -> T {
        return try await withCheckedThrowingContinuation { continuation in
            let lock = NSLock()
            var resumed = false
            func resume(_ result: Result<T, Error>) {
                lock.lock()
                defer { lock.unlock() }
                guard !resumed else { return }
                resumed = true
                continuation.resume(with: result)
            }

            let timeoutItem = DispatchWorkItem {
                resume(.failure(XPCClientError.timeout(operation)))
            }
            DispatchQueue.global(qos: .utility)
                .asyncAfter(deadline: .now() + timeout, execute: timeoutItem)

            let errorHandler: (Error) -> Void = { error in
                timeoutItem.cancel()
                resume(.failure(error))
            }

            let proxy: any AgtmuxDaemonServiceXPCProtocol
            if let proxyProviderOverride {
                guard let overrideProxy = proxyProviderOverride(errorHandler) else {
                    timeoutItem.cancel()
                    resume(.failure(XPCClientError.proxyUnavailable))
                    return
                }
                proxy = overrideProxy
            } else {
                let conn = getConnection()
                guard let liveProxy = conn.remoteObjectProxyWithErrorHandler(errorHandler)
                    as? AgtmuxDaemonServiceXPCProtocol else {
                    timeoutItem.cancel()
                    resume(.failure(XPCClientError.proxyUnavailable))
                    return
                }
                proxy = liveProxy
            }

            call(proxy) { result in
                timeoutItem.cancel()
                resume(result)
            }
        }
    }
}
