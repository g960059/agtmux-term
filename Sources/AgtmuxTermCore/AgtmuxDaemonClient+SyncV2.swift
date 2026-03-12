import Foundation
import Darwin

extension AgtmuxDaemonClient: AgtmuxSyncV3Transport {
    package func fetchBootstrapV3() async throws -> AgtmuxSyncV3Bootstrap {
        if let inlineJSON = ProcessInfo.processInfo.environment["AGTMUX_UI_BOOTSTRAP_V3_JSON"] {
            guard let data = inlineJSON.data(using: .utf8) else {
                throw DaemonError.parseError("AGTMUX_UI_BOOTSTRAP_V3_JSON is not valid UTF-8")
            }
            return try Self.decodeJSONPayload(AgtmuxSyncV3Bootstrap.self, from: data, label: "AGTMUX_UI_BOOTSTRAP_V3_JSON")
        }

        try ensureManagedRuntimeConfigured(forInlineOverrideKeys: ["AGTMUX_UI_BOOTSTRAP_V3_JSON"])
        return try rpcCall(
            method: "ui.bootstrap.v3",
            params: EmptyRPCParams()
        )
    }

    package func fetchChangesV3(cursor: AgtmuxSyncV3Cursor, limit: Int) async throws -> AgtmuxSyncV3ChangesResponse {
        if let inlineJSON = ProcessInfo.processInfo.environment["AGTMUX_UI_CHANGES_V3_JSON"] {
            guard let data = inlineJSON.data(using: .utf8) else {
                throw DaemonError.parseError("AGTMUX_UI_CHANGES_V3_JSON is not valid UTF-8")
            }
            return try Self.decodeJSONPayload(AgtmuxSyncV3ChangesResponse.self, from: data, label: "AGTMUX_UI_CHANGES_V3_JSON")
        }

        try ensureManagedRuntimeConfigured(forInlineOverrideKeys: ["AGTMUX_UI_CHANGES_V3_JSON"])
        return try rpcCall(
            method: "ui.changes.v3",
            params: ChangesV3RPCParams(cursor: cursor, limit: limit)
        )
    }

    package func waitForChangesV1(cursor: AgtmuxSyncV3Cursor, timeoutMs: UInt64) async throws -> AgtmuxSyncV3ChangesResponse {
        let serverTimeout = Double(timeoutMs) / 1000.0
        return try rpcCall(
            method: "ui.wait_for_changes.v1",
            params: WaitForChangesV1Params(cursor: cursor, timeoutMs: timeoutMs),
            timeout: serverTimeout + 2.0
        )
    }

    package func fetchUIHealthV1() async throws -> AgtmuxUIHealthV1 {
        if let inlineJSON = ProcessInfo.processInfo.environment["AGTMUX_UI_HEALTH_V1_JSON"] {
            guard let data = inlineJSON.data(using: .utf8) else {
                throw DaemonError.parseError("AGTMUX_UI_HEALTH_V1_JSON is not valid UTF-8")
            }
            return try Self.decodeJSONPayload(AgtmuxUIHealthV1.self, from: data, label: "AGTMUX_UI_HEALTH_V1_JSON")
        }

        try ensureManagedRuntimeConfigured(forInlineOverrideKeys: ["AGTMUX_UI_HEALTH_V1_JSON"])
        return try rpcCall(
            method: "ui.health.v1",
            params: EmptyRPCParams()
        )
    }
}

private extension AgtmuxDaemonClient {
    struct EmptyRPCParams: Encodable {}

    struct ChangesV3RPCParams: Encodable {
        let cursor: AgtmuxSyncV3Cursor
        let limit: Int
    }

    struct WaitForChangesV1Params: Encodable {
        let cursor: AgtmuxSyncV3Cursor
        let timeoutMs: UInt64
        enum CodingKeys: String, CodingKey {
            case cursor
            case timeoutMs = "timeout_ms"
        }
    }

    struct RPCRequest<Params: Encodable>: Encodable {
        let jsonrpc = "2.0"
        let method: String
        let params: Params
        let id = 1
    }

    struct RPCResponse<Result: Decodable>: Decodable {
        let result: Result?
        let error: RPCErrorPayload?
    }

    struct RPCErrorPayload: Decodable {
        let code: Int?
        let message: String
    }

    func rpcCall<Result: Decodable, Params: Encodable>(
        method: String,
        params: Params,
        timeout: TimeInterval = 5.0
    ) throws -> Result {
        let request = RPCRequest(method: method, params: params)
        let encoder = JSONEncoder()
        let requestData = try encoder.encode(request) + Data("\n".utf8)
        let responseData = try Self.sendRPCRequest(
            socketPath: socketPath,
            requestData: requestData,
            timeout: timeout
        )

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let response: RPCResponse<Result>
        do {
            response = try decoder.decode(RPCResponse<Result>.self, from: responseData)
        } catch {
            throw DaemonError.parseError("RPC \(method) parse failed: \(error.localizedDescription)")
        }
        if let error = response.error {
            throw Self.classifyRPCError(method: method, error: error)
        }
        guard let result = response.result else {
            throw DaemonError.parseError("RPC \(method) returned no result")
        }
        return result
    }

    static func decodeJSONPayload<Result: Decodable>(
        _ type: Result.Type,
        from data: Data,
        label: String
    ) throws -> Result {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(Result.self, from: data)
        } catch {
            throw DaemonError.parseError("\(label) parse failed: \(error.localizedDescription)")
        }
    }

    static func classifyRPCError(method: String, error: RPCErrorPayload) -> DaemonError {
        let message = error.message.trimmingCharacters(in: .whitespacesAndNewlines)
        if isMethodNotFound(error: error) {
            switch method {
            case "ui.bootstrap.v3", "ui.changes.v3", "ui.wait_for_changes.v1":
                return .makeSyncV3MethodNotFoundError(
                    method: method,
                    rpcCode: error.code,
                    message: message
                )
            case "ui.health.v1":
                return .makeUIHealthMethodNotFoundError(
                    method: method,
                    rpcCode: error.code,
                    message: message
                )
            default:
                break
            }
        }
        return .processError(
            exitCode: -3,
            stderr: "RPC \(method) failed (\(error.code ?? -1)): \(message)"
        )
    }

    static func isMethodNotFound(error: RPCErrorPayload) -> Bool {
        if error.code == -32601 {
            return true
        }
        return error.message.localizedCaseInsensitiveContains("method not found")
    }

    static func sendRPCRequest(
        socketPath: String,
        requestData: Data,
        timeout: TimeInterval
    ) throws -> Data {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw DaemonError.processError(exitCode: -3, stderr: "socket creation failed")
        }
        defer { close(fd) }

        try setSocketTimeout(fd: fd, timeout: timeout)
        try connect(fd: fd, socketPath: socketPath)
        try writeAll(fd: fd, data: requestData)
        _ = Darwin.shutdown(fd, SHUT_WR)
        return try readResponseLine(fd: fd)
    }

    static func setSocketTimeout(fd: Int32, timeout: TimeInterval) throws {
        let seconds = floor(timeout)
        let microseconds = (timeout - seconds) * 1_000_000
        var value = timeval(
            tv_sec: Int(seconds),
            tv_usec: Int32(microseconds)
        )

        let resultSend = withUnsafePointer(to: &value) { pointer in
            setsockopt(
                fd,
                SOL_SOCKET,
                SO_SNDTIMEO,
                pointer,
                socklen_t(MemoryLayout<timeval>.size)
            )
        }
        let resultRecv = withUnsafePointer(to: &value) { pointer in
            setsockopt(
                fd,
                SOL_SOCKET,
                SO_RCVTIMEO,
                pointer,
                socklen_t(MemoryLayout<timeval>.size)
            )
        }

        guard resultSend == 0, resultRecv == 0 else {
            throw DaemonError.processError(exitCode: -3, stderr: "failed to set socket timeout")
        }
    }

    static func connect(fd: Int32, socketPath: String) throws {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)

        let pathBytes = socketPath.utf8CString
        let maxLength = MemoryLayout.size(ofValue: address.sun_path)
        guard pathBytes.count <= maxLength else {
            throw DaemonError.processError(
                exitCode: -3,
                stderr: "socket path too long (\(pathBytes.count) > \(maxLength)): \(socketPath)"
            )
        }

        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            let rawPointer = UnsafeMutableRawPointer(pointer).assumingMemoryBound(to: CChar.self)
            rawPointer.initialize(repeating: 0, count: maxLength)
            _ = pathBytes.withUnsafeBufferPointer { bytes in
                strncpy(rawPointer, bytes.baseAddress, maxLength - 1)
            }
        }

        let addressLength = socklen_t(
            MemoryLayout<sa_family_t>.size + pathBytes.count
        )
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { rebound in
                Darwin.connect(fd, rebound, addressLength)
            }
        }

        guard result == 0 else {
            let message = String(cString: strerror(errno))
            throw DaemonError.processError(
                exitCode: -3,
                stderr: "cannot connect to daemon at \(socketPath): \(message)"
            )
        }
    }

    static func writeAll(fd: Int32, data: Data) throws {
        try data.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            var written = 0
            while written < data.count {
                let pointer = baseAddress.advanced(by: written)
                let result = Darwin.write(fd, pointer, data.count - written)
                if result < 0 {
                    let message = String(cString: strerror(errno))
                    throw DaemonError.processError(exitCode: -3, stderr: "socket write failed: \(message)")
                }
                written += result
            }
        }
    }

    static func readResponseLine(fd: Int32) throws -> Data {
        var response = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)

        while true {
            let count = Darwin.read(fd, &chunk, chunk.count)
            if count < 0 {
                let message = String(cString: strerror(errno))
                throw DaemonError.processError(exitCode: -3, stderr: "socket read failed: \(message)")
            }
            if count == 0 {
                break
            }

            response.append(contentsOf: chunk.prefix(count))
            if response.contains(0x0A) {
                break
            }
        }

        guard !response.isEmpty else {
            throw DaemonError.parseError("RPC response was empty")
        }
        if let newline = response.firstIndex(of: 0x0A) {
            response.removeSubrange(newline..<response.endIndex)
        }
        return response
    }
}
