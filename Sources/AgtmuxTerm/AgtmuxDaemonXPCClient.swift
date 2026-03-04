import Foundation
import AgtmuxTermCore

enum XPCClientError: Error {
    case unavailable
    case proxyUnavailable
    case remote(String)
    case timeout(String)
    case decode(String)
}

actor AgtmuxDaemonXPCClient: LocalSnapshotClient {
    private let serviceName: String
    private var connection: NSXPCConnection?
    // Performance hint only. Service-side fetchSnapshot always re-checks startIfNeeded.
    private var daemonStartedInSession = false

    init(serviceName: String = AgtmuxDaemonXPC.serviceName) {
        self.serviceName = serviceName
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

    // MARK: - Internal

    private func getConnection() -> NSXPCConnection {
        if let connection { return connection }

        let newConnection = NSXPCConnection(serviceName: serviceName)
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

    private func invoke<T>(
        timeout: TimeInterval,
        operation: String,
        _ call: @escaping (AgtmuxDaemonServiceXPCProtocol, @escaping (Result<T, Error>) -> Void) -> Void
    ) async throws -> T {
        let conn = getConnection()

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

            guard let proxy = conn.remoteObjectProxyWithErrorHandler({ error in
                timeoutItem.cancel()
                resume(.failure(error))
            }) as? AgtmuxDaemonServiceXPCProtocol else {
                timeoutItem.cancel()
                resume(.failure(XPCClientError.proxyUnavailable))
                return
            }

            call(proxy) { result in
                timeoutItem.cancel()
                resume(result)
            }
        }
    }
}
