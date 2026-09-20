import XCTest
@testable import MySidepulsePlatform

final class ControlTests: XCTestCase {
    func socketPath() -> String {
        // sockaddr_un.sun_path caps at 104 bytes — keep it short.
        "/tmp/mysidepulse-test-\(UInt32.random(in: 0..<UInt32.max)).sock"
    }

    func testRoundTrip() throws {
        let path = socketPath()
        let server = ControlServer(socketPath: path)
        server.handler = { request in
            if request.cmd == "ping" { return ControlResponse(ok: true) }
            if request.cmd == "led" {
                return ControlResponse(ok: true, mode: request.mode)
            }
            return ControlResponse(ok: false, error: "unknown command")
        }
        try server.start()
        defer { server.stop() }

        XCTAssertEqual(ControlClient.send(ControlRequest(cmd: "ping"), socketPath: path)?.ok, true)
        let led = ControlClient.send(ControlRequest(cmd: "led", mode: "#ff0000"), socketPath: path)
        XCTAssertEqual(led?.mode, "#ff0000")
        let bad = ControlClient.send(ControlRequest(cmd: "nope"), socketPath: path)
        XCTAssertEqual(bad?.ok, false)
    }

    func testClientAgainstDeadSocketReturnsNil() {
        XCTAssertNil(ControlClient.send(ControlRequest(cmd: "ping"), socketPath: socketPath()))
    }

    func testSocketPermissionsAreOwnerOnly() throws {
        let path = socketPath()
        let server = ControlServer(socketPath: path)
        server.handler = { _ in ControlResponse(ok: true) }
        try server.start()
        defer { server.stop() }
        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.uint16Value, 0o600)
    }

    func testServerSurvivesGarbageRequest() throws {
        let path = socketPath()
        let server = ControlServer(socketPath: path)
        server.handler = { _ in ControlResponse(ok: true) }
        try server.start()
        defer { server.stop() }
        // Raw garbage connection…
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = ControlSocketAddress.make(path: path)
        _ = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        _ = "garbage\n".withCString { write(fd, $0, 8) }
        close(fd)
        // …must not kill the server for the next client.
        XCTAssertEqual(ControlClient.send(ControlRequest(cmd: "ping"), socketPath: path)?.ok, true)
    }

    func testStartRefusesToStealALiveSocket() throws {
        let path = socketPath()
        let first = ControlServer(socketPath: path)
        first.handler = { _ in ControlResponse(ok: true) }
        try first.start()
        defer { first.stop() }

        let second = ControlServer(socketPath: path)
        second.handler = { _ in ControlResponse(ok: false, error: "second") }
        XCTAssertThrowsError(try second.start()) { error in
            XCTAssertEqual(error as? ControlServerError, .alreadyRunning)
        }
        XCTAssertEqual(ControlClient.send(ControlRequest(cmd: "ping"), socketPath: path)?.ok, true,
                       "the original server must still be reachable")
    }

    /// A bind that fails once must not leave the app headless for the rest
    /// of its run — the strip keeps working, but every CLI command would
    /// have nothing to talk to without a retry that takes over the socket.
    func testAServerThatCouldNotBindKeepsTryingAndTakesOverWhenItCan() throws {
        let path = socketPath()
        let squatter = ControlServer(socketPath: path)
        squatter.handler = { _ in ControlResponse(ok: false, error: "squatter") }
        try squatter.start()

        let failures = expectation(description: "first attempt reported")
        failures.assertForOverFulfill = false
        let server = ControlServer(socketPath: path)
        server.handler = { _ in ControlResponse(ok: true) }
        defer { server.stop() }
        server.startRetrying(every: 0.2) { error in
            XCTAssertEqual(error as? ControlServerError, .alreadyRunning)
            failures.fulfill()
        }
        wait(for: [failures], timeout: 2)
        XCTAssertFalse(server.isServing)

        // The socket frees up; the retry must claim it with no restart.
        squatter.stop()
        let deadline = Date().addingTimeInterval(5)
        while !server.isServing, Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        XCTAssertTrue(server.isServing, "the retry never took the socket over")
        XCTAssertEqual(ControlClient.send(ControlRequest(cmd: "ping"), socketPath: path)?.ok, true)
    }

    func testStopOnAServerThatNeverBoundLeavesTheLiveSocketAlone() throws {
        let path = socketPath()
        let first = ControlServer(socketPath: path)
        first.handler = { _ in ControlResponse(ok: true) }
        try first.start()
        defer { first.stop() }

        let second = ControlServer(socketPath: path)
        second.handler = { _ in ControlResponse(ok: false, error: "second") }
        XCTAssertThrowsError(try second.start())
        // Quitting the instance that never owned the socket must not unlink it.
        second.stop()
        XCTAssertTrue(FileManager.default.fileExists(atPath: path),
                      "the live instance's socket file must survive")
        XCTAssertEqual(ControlClient.send(ControlRequest(cmd: "ping"), socketPath: path)?.ok, true,
                       "the CLI must still reach the running instance")
    }

    func testStartReclaimsAStaleSocketFile() throws {
        let path = socketPath()
        // A leftover file with nobody listening, as a crash would leave behind.
        FileManager.default.createFile(atPath: path, contents: Data("stale".utf8))
        let server = ControlServer(socketPath: path)
        server.handler = { _ in ControlResponse(ok: true) }
        XCTAssertNoThrow(try server.start())
        defer { server.stop() }
        XCTAssertEqual(ControlClient.send(ControlRequest(cmd: "ping"), socketPath: path)?.ok, true)
    }

    // MARK: the shapes added for jobs and notifications

    func roundTrip<T: Codable & Equatable>(_ value: T) throws -> T {
        try JSONDecoder().decode(T.self, from: JSONEncoder().encode(value))
    }

    func testJobRequestRoundTrips() throws {
        let request = ControlRequest(cmd: "job-begin", job: JobRequest(
            id: "zsh-900", pid: 900, label: "npm build", exitCode: nil,
            showAfterSeconds: 10, hostBundleId: "com.mitchellh.ghostty"))
        XCTAssertEqual(try roundTrip(request), request)
    }

    func testNotifyRequestRoundTrips() throws {
        let request = ControlRequest(cmd: "notify", notify: NotifyRequest(
            enabled: true, topic: "cc-abc", server: "https://ntfy.sh", test: false))
        XCTAssertEqual(try roundTrip(request), request)
    }

    /// A CLI from a previous install must keep working against a newer app,
    /// and vice versa: every added field is optional.
    func testAnOldShapedRequestStillDecodes() throws {
        let data = Data(#"{"cmd":"led","mode":"auto"}"#.utf8)
        let request = try JSONDecoder().decode(ControlRequest.self, from: data)
        XCTAssertEqual(request.cmd, "led")
        XCTAssertEqual(request.mode, "auto")
        XCTAssertNil(request.job)
        XCTAssertNil(request.notify)
    }

    func testAnOldShapedResponseStillDecodes() throws {
        let data = Data(#"{"ok":true,"mode":"auto","display":"working"}"#.utf8)
        let response = try JSONDecoder().decode(ControlResponse.self, from: data)
        XCTAssertTrue(response.ok)
        XCTAssertNil(response.jobs)
        XCTAssertNil(response.notify)
    }

    func testResponseCarriesJobsAndNotifyStatus() throws {
        let response = ControlResponse(
            ok: true,
            jobs: [JobStatus(id: "zsh-900", state: "running", label: "npm build", ageSeconds: 3)],
            notify: NotifyStatus(enabled: true, server: "https://ntfy.sh",
                                 topicMasked: "cc-abc…", topicUsable: true))
        XCTAssertEqual(try roundTrip(response), response)
    }

    /// `mysidepulse status --json` dumps the whole response, and that output is
    /// what gets pasted into an issue. The raw topic is bearer-equivalent, so
    /// NotifyStatus has nowhere to put one: only the `notify` command's own
    /// response field carries it.
    func testAStatusResponseHasNowhereToPutTheRawTopic() throws {
        let response = ControlResponse(
            ok: true, mode: "auto", display: "working",
            notify: NotifyStatus(enabled: true, server: "https://ntfy.sh",
                                 topicMasked: "cc-abc…", topicUsable: true))
        let json = String(decoding: try JSONEncoder().encode(response), as: UTF8.self)
        XCTAssertTrue(json.contains("cc-abc…"))
        XCTAssertFalse(json.contains("\"topic\""), "no raw-topic field exists on a status response")
        XCTAssertNil(response.notifyTopic)
    }
}