import XCTest
@testable import MySidepulsePlatform
import MySidepulseCore

final class NotifierTests: XCTestCase {
    func request(server: String = K.notifyServerDefault, topic: String = "cc-abc123",
                 title: String = "Claude Code", tag: String = "white_check_mark",
                 click: String = "https://claude.ai/code/session_1",
                 message: String = "Finished") -> URLRequest? {
        Notifier.request(server: server, topic: topic, title: title, tag: tag,
                         click: click, message: message)
    }

    /// The exact request ntfy expects, header for header.
    // MARK: delivery

    /// Stands in for the network. Each request pops the next scripted outcome;
    /// running out means "succeed", so a test only scripts the failures it
    /// cares about.
    final class StubTransport: URLProtocol {
        static let lock = NSLock()
        static var outcomes: [Int?] = []   // status code, or nil for a transport error
        static var attempts = 0

        static func script(_ outcomes: [Int?]) {
            lock.lock(); defer { lock.unlock() }
            self.outcomes = outcomes
            attempts = 0
        }
        static var attemptCount: Int { lock.lock(); defer { lock.unlock() }; return attempts }

        static func session() -> URLSession {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [StubTransport.self]
            return URLSession(configuration: configuration)
        }

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func stopLoading() {}
        override func startLoading() {
            Self.lock.lock()
            let outcome: Int? = Self.attempts < Self.outcomes.count ? Self.outcomes[Self.attempts] : 200
            Self.attempts += 1
            Self.lock.unlock()
            guard let code = outcome else {
                client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
                return
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: code,
                                           httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    func pushRequest() -> URLRequest {
        Notifier.request(server: "https://ntfy.example", topic: "cc-test", title: "t",
                         tag: "bell", click: "https://claude.ai/code", message: "m")!
    }

    /// The lid closes, the user walks off, and wifi has not finished
    /// reassociating — the exact moment the push matters most. A single POST
    /// must not be the whole delivery.
    func testATransportFailureIsRetriedUntilItLands() {
        StubTransport.script([nil, nil])
        let delivered = expectation(description: "no final failure reported")
        delivered.isInverted = true
        Notifier.send(pushRequest(), session: StubTransport.session(), retryDelay: 0.05) { reason in
            if !reason.contains("retrying") { delivered.fulfill() }
        }
        wait(for: [delivered], timeout: 2)
        XCTAssertEqual(StubTransport.attemptCount, 3, "two failures, then the one that landed")
    }

    func testRetriesStopAtTheBudgetAndReportTheFailure() {
        StubTransport.script([nil, nil, nil, nil, nil])
        let failed = expectation(description: "final failure reported")
        Notifier.send(pushRequest(), session: StubTransport.session(), retryDelay: 0.05) { reason in
            if !reason.contains("retrying") { failed.fulfill() }
        }
        wait(for: [failed], timeout: 3)
        XCTAssertEqual(StubTransport.attemptCount, K.notifyMaxAttempts,
                       "the budget is what stops a push arriving long after it meant anything")
    }

    func testAServerErrorIsRetriedButABadRequestIsNot() {
        StubTransport.script([500])
        let landed = expectation(description: "retried past the 500")
        landed.isInverted = true
        Notifier.send(pushRequest(), session: StubTransport.session(), retryDelay: 0.05) { reason in
            if !reason.contains("retrying") { landed.fulfill() }
        }
        wait(for: [landed], timeout: 2)
        XCTAssertEqual(StubTransport.attemptCount, 2)

        // A 4xx is the server rejecting this request, not the network dropping
        // it: sending the same bytes again would only be rejected again.
        StubTransport.script([404, 404, 404])
        let refused = expectation(description: "reported without retrying")
        Notifier.send(pushRequest(), session: StubTransport.session(), retryDelay: 0.05) { reason in
            XCTAssertEqual(reason, "HTTP 404")
            refused.fulfill()
        }
        wait(for: [refused], timeout: 2)
        XCTAssertEqual(StubTransport.attemptCount, 1)
    }

    func testASuccessfulPushNeverReportsFailure() {
        StubTransport.script([200])
        let quiet = expectation(description: "no failure")
        quiet.isInverted = true
        Notifier.send(pushRequest(), session: StubTransport.session(), retryDelay: 0.05) { _ in
            quiet.fulfill()
        }
        wait(for: [quiet], timeout: 1)
        XCTAssertEqual(StubTransport.attemptCount, 1)
    }

    func testRequestShapeIsExact() throws {
        let r = try XCTUnwrap(request())
        XCTAssertEqual(r.url?.absoluteString, "https://ntfy.sh/cc-abc123")
        XCTAssertEqual(r.httpMethod, "POST")
        XCTAssertEqual(r.value(forHTTPHeaderField: "Title"), "Claude Code")
        XCTAssertEqual(r.value(forHTTPHeaderField: "Tags"), "white_check_mark")
        XCTAssertEqual(r.value(forHTTPHeaderField: "Click"), "https://claude.ai/code/session_1")
        XCTAssertEqual(r.httpBody.map { String(decoding: $0, as: UTF8.self) }, "Finished")
        XCTAssertEqual(r.timeoutInterval, K.notifyTimeoutSeconds)
    }

    func testACustomServerIsHonoured() throws {
        let r = try XCTUnwrap(request(server: "https://ntfy.example.com"))
        XCTAssertEqual(r.url?.absoluteString, "https://ntfy.example.com/cc-abc123")
    }

    func testATrailingSlashOnTheServerDoesNotDoubleUp() throws {
        let r = try XCTUnwrap(request(server: "https://ntfy.sh/"))
        XCTAssertEqual(r.url?.absoluteString, "https://ntfy.sh/cc-abc123")
    }

    /// A topic comes out of a config file, so it is not trusted to be a safe
    /// path component. Refusing beats silently posting somewhere else.
    func testAnUnsafeTopicIsRefused() {
        for topic in ["", "has space", "a/b", "../other", "x?y", "café"] {
            XCTAssertNil(request(topic: topic), "topic \(topic.debugDescription) must be refused")
        }
    }

    func testAPlausibleTopicIsAccepted() {
        for topic in ["cc-abc123", "A_b-9", String(repeating: "t", count: 64)] {
            XCTAssertNotNil(request(topic: topic), topic)
        }
    }

    func testANonHttpServerIsRefused() {
        XCTAssertNil(request(server: "not a url"))
        XCTAssertNil(request(server: "file:///etc/passwd"))
    }

    /// Doctor output gets pasted into issues and transcripts, and a leaked
    /// topic is a burned topic. Only the deliberate notify commands print
    /// the whole thing.
    func testAMaskedTopicKeepsMostOfItselfBack() {
        XCTAssertEqual(Notifier.maskTopic("cc-0123456789abcdef"), "cc-012…")
        XCTAssertEqual(Notifier.maskTopic(nil), "(none)")
        XCTAssertFalse(Notifier.maskTopic("cc-0123456789abcdef").contains("789"))
    }

    /// The topic is bearer-equivalent, so a generated one must not be
    /// guessable and must be a legal topic.
    func testAGeneratedTopicIsLongRandomAndUsable() {
        let a = Notifier.generateTopic()
        let b = Notifier.generateTopic()
        XCTAssertNotEqual(a, b)
        XCTAssertGreaterThanOrEqual(a.count, 24)
        XCTAssertNotNil(request(topic: a))
    }
}

final class ClaudeSessionsTests: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mysidepulse-sessions-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    func write(_ name: String, _ json: String) throws {
        try json.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    func testFindsTheRecordAmongSeveralFiles() throws {
        try write("111.json", #"{"sessionId":"other","kind":"interactive"}"#)
        try write("222.json", #"{"sessionId":"mine","kind":"interactive","bridgeSessionId":"session_xyz"}"#)
        let record = ClaudeSessions.find(sessionId: "mine", in: dir)
        XCTAssertEqual(record?.bridgeSessionId, "session_xyz")
        XCTAssertEqual(record?.kind, "interactive")
    }

    func testTheDeepLinkUsesTheBridgeSessionId() throws {
        try write("222.json", #"{"sessionId":"mine","bridgeSessionId":"session_xyz"}"#)
        XCTAssertEqual(ClaudeSessions.link(for: ClaudeSessions.find(sessionId: "mine", in: dir)),
                       "https://claude.ai/code/session_xyz")
    }

    func testAnUnknownSessionFallsBackToTheBareLink() {
        XCTAssertNil(ClaudeSessions.find(sessionId: "nobody", in: dir))
        XCTAssertEqual(ClaudeSessions.link(for: nil), "https://claude.ai/code")
    }

    func testARecordWithoutABridgeIdFallsBackToo() throws {
        try write("222.json", #"{"sessionId":"mine","kind":"interactive"}"#)
        XCTAssertEqual(ClaudeSessions.link(for: ClaudeSessions.find(sessionId: "mine", in: dir)),
                       "https://claude.ai/code")
    }

    /// A background or daemon session is an agent of its own; it lights the
    /// strip but must not ring a phone.
    func testBackgroundAndDaemonSessionsAreSilent() throws {
        for kind in ["bg", "daemon", "daemon-worker"] {
            try write("k.json", #"{"sessionId":"mine","kind":"\#(kind)"}"#)
            XCTAssertTrue(ClaudeSessions.isSilent(ClaudeSessions.find(sessionId: "mine", in: dir)), kind)
        }
        try write("k.json", #"{"sessionId":"mine","kind":"interactive"}"#)
        XCTAssertFalse(ClaudeSessions.isSilent(ClaudeSessions.find(sessionId: "mine", in: dir)))
    }

    func testAnUnregisteredSessionStillNotifies() {
        XCTAssertFalse(ClaudeSessions.isSilent(nil), "no record is not a reason to stay quiet")
    }

    func testAMalformedFileDoesNotStopTheSearch() throws {
        try write("aaa.json", "{ this is not json")
        try write("bbb.json", #"{"sessionId":"mine","bridgeSessionId":"session_xyz"}"#)
        XCTAssertEqual(ClaudeSessions.find(sessionId: "mine", in: dir)?.bridgeSessionId, "session_xyz")
    }

    func testAMissingDirectoryIsNotAnError() {
        XCTAssertNil(ClaudeSessions.find(sessionId: "mine",
                                         in: dir.appendingPathComponent("nope")))
    }
}
