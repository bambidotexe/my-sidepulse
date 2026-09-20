import XCTest
@testable import MySidepulsePlatform
import MySidepulseCore

final class UpdateCheckerTests: XCTestCase {
    /// Stands in for GitHub: one scripted reply, and a record of what was asked.
    final class StubGitHub: URLProtocol {
        static let lock = NSLock()
        static var reply: (status: Int, body: Data)?   // nil is a transport error
        static var asked: [URLRequest] = []

        static func script(status: Int, body: Data) {
            lock.lock(); defer { lock.unlock() }
            reply = (status, body); asked = []
        }
        static func scriptOffline() {
            lock.lock(); defer { lock.unlock() }
            reply = nil; asked = []
        }
        static var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return asked }

        static func configuration() -> URLSessionConfiguration {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [StubGitHub.self]
            return configuration
        }
        static func session() -> URLSession { URLSession(configuration: configuration()) }

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func stopLoading() {}
        override func startLoading() {
            Self.lock.lock()
            Self.asked.append(request)
            let reply = Self.reply
            Self.lock.unlock()
            guard let reply else {
                client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
                return
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: reply.status,
                                           httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: reply.body)
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    var dir: URL!
    override func setUp() {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mysidepulse-updates-\(UUID().uuidString)")
    }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    let latest = Data(#"""
    { "tag_name": "v1.8.0", "assets": [
      { "name": "MySidepulse-1.8.0.dmg", "browser_download_url": "https://example.com/MySidepulse-1.8.0.dmg" } ] }
    """#.utf8)
    let release = LatestRelease(version: ReleaseVersion(1, 8, 0),
                                dmgURL: URL(string: "https://example.com/MySidepulse-1.8.0.dmg")!)

    func check(current: String = "1.7.0") -> Result<UpdateDecision, Error> {
        let done = expectation(description: "checked")
        var result: Result<UpdateDecision, Error>!
        UpdateChecker.check(current: current, session: StubGitHub.session()) { result = $0; done.fulfill() }
        wait(for: [done], timeout: 5)
        return result
    }

    /// One fetch through the stub, of `release` or of one GitHub said more about.
    func download(_ release: LatestRelease? = nil) -> Result<URL, Error> {
        let release = release ?? self.release
        let done = expectation(description: "downloaded")
        var result: Result<URL, Error>!
        let download = UpdateDownload(release: release,
                                      destination: dir.appendingPathComponent("MySidepulse-1.8.0.dmg"),
                                      configuration: StubGitHub.configuration(),
                                      onProgress: { _, _ in },
                                      onDone: { result = $0; done.fulfill() })
        download.start()
        wait(for: [done], timeout: 5)
        return result
    }

    func testTheCheckAsksTheReleasesAPIOnceAndReportsANewerRelease() throws {
        StubGitHub.script(status: 200, body: latest)
        XCTAssertEqual(try check().get(), .available(release))
        XCTAssertEqual(StubGitHub.requests.map(\.url), [UpdateCheck.latestReleaseAPI])
        XCTAssertEqual(StubGitHub.requests.first?.value(forHTTPHeaderField: "Accept"),
                       "application/vnd.github+json")
        XCTAssertNil(StubGitHub.requests.first?.value(forHTTPHeaderField: "Authorization"),
                     "anonymous: the app holds no GitHub credential")
    }

    func testTheSameReleaseIsUpToDateAndNoReleaseIsNotAnError() throws {
        StubGitHub.script(status: 200, body: latest)
        XCTAssertEqual(try check(current: "1.8.0").get(), .upToDate)
        StubGitHub.script(status: 404, body: Data())
        XCTAssertEqual(try check().get(), .noRelease)
    }

    func testARefusalOrNoNetworkIsAFailureNotUpToDateAndIsNotRetried() {
        StubGitHub.script(status: 403, body: Data())
        XCTAssertThrowsError(try check().get()) { XCTAssertEqual($0 as? UpdateFailure, .httpStatus(403)) }
        StubGitHub.scriptOffline()
        XCTAssertThrowsError(try check().get())
        XCTAssertEqual(StubGitHub.requests.count, 1, "pressing the button again is the retry")
    }

    func testTheDownloadLandsWhereItIsToldAndReplacesWhatWasThere() throws {
        StubGitHub.script(status: 200, body: Data("disk image".utf8))
        let url = try download().get()
        XCTAssertEqual(url.lastPathComponent, "MySidepulse-1.8.0.dmg")
        XCTAssertEqual(try Data(contentsOf: url), Data("disk image".utf8))
        XCTAssertNoThrow(try download().get(), "downloading the same version again replaces it")
    }

    /// GitHub states the asset's length and SHA-256; a file that is not the one
    /// it described never reaches the disk image tools.
    func testAFileThatIsNotTheOneGitHubDescribedIsRefusedAndRemoved() throws {
        let body = Data("disk image".utf8)
        // Sixty-four hex digits that are not this body's digest.
        let digest = "0b26ae5b1ba5e8b4e1a7c3a2d6f8d0d2a0e1e8f3e2b9d6c4a7f1b3c5d7e9f0a1"
        StubGitHub.script(status: 200, body: body)
        let described = LatestRelease(version: release.version, dmgURL: release.dmgURL,
                                      dmgSize: Int64(body.count), dmgSHA256: UpdateDownload.sha256(of: body))
        XCTAssertNoThrow(try download(described).get())

        let wrongDigest = LatestRelease(version: release.version, dmgURL: release.dmgURL,
                                        dmgSize: Int64(body.count), dmgSHA256: digest)
        XCTAssertThrowsError(try download(wrongDigest).get()) {
            XCTAssertEqual($0 as? UpdateDownload.Failure, .damaged)
        }
        let wrongSize = LatestRelease(version: release.version, dmgURL: release.dmgURL, dmgSize: 3)
        XCTAssertThrowsError(try download(wrongSize).get()) {
            XCTAssertEqual($0 as? UpdateDownload.Failure, .damaged)
        }
        XCTAssertEqual((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [], [])
    }

    func testACancelledDownloadReportsNothing() {
        StubGitHub.script(status: 200, body: Data("disk image".utf8))
        let silent = expectation(description: "never told")
        silent.isInverted = true
        let download = UpdateDownload(release: release, destination: dir.appendingPathComponent("M.dmg"),
                                      configuration: StubGitHub.configuration(),
                                      onProgress: { _, _ in }, onDone: { _ in silent.fulfill() })
        download.start()
        download.cancel()
        wait(for: [silent], timeout: 0.5)
    }

    /// What a fetch leaves behind goes before the next one; what the install
    /// helper may still need, and anything that is not the update's, stays.
    func testTheSweepRemovesAFetchAndNeverThePreviousBundle() throws {
        let files = FileManager.default
        for folder in ["staged/MySidepulse.app", "previous/MySidepulse.app", "mount"] {
            try files.createDirectory(at: dir.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        for file in ["MySidepulse-1.7.5.dmg", "install.sh", "install.log", "result", "notes.txt"] {
            try Data("x".utf8).write(to: dir.appendingPathComponent(file))
        }
        UpdateInstaller.sweep(dir)
        XCTAssertEqual(try files.contentsOfDirectory(atPath: dir.path).sorted(),
                       ["install.log", "mount", "notes.txt", "previous", "result"])
    }

    /// A download task hands over a 404's error page as if it were the file.
    func testAnErrorPageIsNotSavedAsADiskImage() throws {
        StubGitHub.script(status: 404, body: Data("Not Found".utf8))
        XCTAssertThrowsError(try download().get()) { XCTAssertEqual($0 as? UpdateFailure, .httpStatus(404)) }
        let saved = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        XCTAssertEqual(saved, [])
    }
}
