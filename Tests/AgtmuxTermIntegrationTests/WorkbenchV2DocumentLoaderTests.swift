import XCTest
@testable import AgtmuxTerm
import AgtmuxTermCore

final class WorkbenchV2DocumentLoaderTests: XCTestCase {
    func testLocalDocumentLoadReturnsSnapshot() async throws {
        let tempDirectory = try makeTemporaryDirectory()
        let documentURL = tempDirectory.appendingPathComponent("notes.md")
        try Data("# Hello\nbody\n".utf8).write(to: documentURL)

        let loader = WorkbenchV2DocumentLoader()
        let snapshot = try await loader.load(
            ref: DocumentRef(target: .local, path: documentURL.path),
            hostsConfig: .empty
        )

        XCTAssertEqual(snapshot.text, "# Hello\nbody\n")
        XCTAssertEqual(snapshot.targetLabel, "local")
    }

    func testRemoteDocumentLoadUsesInjectedRunner() async throws {
        let capture = ProcessRunnerCapture()

        let loader = WorkbenchV2DocumentLoader { executableURL, arguments in
            await capture.record(executableURL: executableURL, arguments: arguments)
            return WorkbenchV2ProcessResult(
                stdout: Data("remote body".utf8),
                stderr: Data(),
                exitCode: 0
            )
        }

        let snapshot = try await loader.load(
            ref: DocumentRef(target: .remote(hostKey: "devbox"), path: "/srv/app/README.md"),
            hostsConfig: HostsConfig(hosts: [
                RemoteHost(
                    id: "devbox",
                    displayName: "Devbox",
                    hostname: "devbox.example.com",
                    user: "alice",
                    transport: .ssh
                )
            ])
        )

        let recorded = await capture.snapshot()
        XCTAssertEqual(recorded.executableURL?.path, "/usr/bin/ssh")
        XCTAssertEqual(recorded.arguments.prefix(5), ["-o", "BatchMode=yes", "-o", "ConnectTimeout=5", "-o"])
        XCTAssertTrue(recorded.arguments.contains("alice@devbox.example.com"))
        XCTAssertEqual(recorded.invocationCount, 1)
        XCTAssertEqual(snapshot.text, "remote body")
        XCTAssertEqual(snapshot.targetLabel, "devbox")
    }

    func testRemoteDocumentLoadFailureStaysExplicit() async {
        let loader = WorkbenchV2DocumentLoader { _, _ in
            WorkbenchV2ProcessResult(
                stdout: Data(),
                stderr: Data("permission denied".utf8),
                exitCode: 17
            )
        }

        do {
            _ = try await loader.load(
                ref: DocumentRef(target: .remote(hostKey: "ops"), path: "/var/log/app.log"),
                hostsConfig: HostsConfig(hosts: [
                    RemoteHost(
                        id: "ops",
                        displayName: "Ops",
                        hostname: "ops.example.com",
                        user: nil,
                        transport: .ssh
                    )
                ])
            )
            XCTFail("Expected remote document load to fail explicitly")
        } catch let error as WorkbenchV2DocumentLoadError {
            XCTAssertEqual(
                error,
                .remoteCommandFailed(hostKey: "ops", message: "permission denied")
            )
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testRemoteDocumentLoadFailsWhenConfiguredHostIsMissing() async {
        let capture = ProcessRunnerCapture()
        let loader = WorkbenchV2DocumentLoader { executableURL, arguments in
            await capture.record(executableURL: executableURL, arguments: arguments)
            return WorkbenchV2ProcessResult(
                stdout: Data(),
                stderr: Data(),
                exitCode: 0
            )
        }

        do {
            _ = try await loader.load(
                ref: DocumentRef(target: .remote(hostKey: "missing"), path: "/srv/app/README.md"),
                hostsConfig: .empty
            )
            XCTFail("Expected missing remote host config to fail explicitly")
        } catch let error as WorkbenchV2DocumentLoadError {
            XCTAssertEqual(error, .missingRemoteHostKey("missing"))
            let recorded = await capture.snapshot()
            XCTAssertEqual(recorded.invocationCount, 0)
            XCTAssertNil(recorded.executableURL)
            XCTAssertTrue(recorded.arguments.isEmpty)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testLocalDirectoryLoadFailsExplicitly() async throws {
        let tempDirectory = try makeTemporaryDirectory()
        let nestedDirectory = tempDirectory.appendingPathComponent("docs", isDirectory: true)
        try FileManager.default.createDirectory(at: nestedDirectory, withIntermediateDirectories: true)

        let loader = WorkbenchV2DocumentLoader()

        do {
            _ = try await loader.load(
                ref: DocumentRef(target: .local, path: nestedDirectory.path),
                hostsConfig: .empty
            )
            XCTFail("Expected local directory load to fail explicitly")
        } catch let error as WorkbenchV2DocumentLoadError {
            XCTAssertEqual(error, .directoryNotSupported(nestedDirectory.path))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }
}

private actor ProcessRunnerCapture {
    private(set) var executableURL: URL?
    private(set) var arguments: [String] = []
    private(set) var invocationCount = 0

    func record(executableURL: URL, arguments: [String]) {
        invocationCount += 1
        self.executableURL = executableURL
        self.arguments = arguments
    }

    func snapshot() -> (executableURL: URL?, arguments: [String], invocationCount: Int) {
        (executableURL, arguments, invocationCount)
    }
}
