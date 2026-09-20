import XCTest
import MySidepulseCore

final class UpdateCheckTests: XCTestCase {
    func release(_ version: String) -> LatestRelease {
        LatestRelease(version: ReleaseVersion(string: version)!,
                      dmgURL: URL(string: "https://example.com/MySidepulse-\(version).dmg")!)
    }

    func json(tag: String? = "v1.8.0", assets: [String] = ["MySidepulse-1.8.0.dmg"]) -> Data {
        let list = assets.map {
            #"{ "name": "\#($0)", "browser_download_url": "https://example.com/\#($0)" }"#
        }.joined(separator: ",")
        let tagField = tag.map { #""tag_name": "\#($0)","# } ?? ""
        return Data("{ \(tagField) \"assets\": [\(list)] }".utf8)
    }

    // MARK: ReleaseVersion

    func testAVersionParsesWithOrWithoutTheV() {
        XCTAssertEqual(ReleaseVersion(string: "1.7.0"), ReleaseVersion(1, 7, 0))
        XCTAssertEqual(ReleaseVersion(string: "v1.7.0"), ReleaseVersion(1, 7, 0))
        XCTAssertEqual(ReleaseVersion(string: "v1.7.0")?.displayString, "1.7.0")
    }

    func testWhatIsNotAVersionIsRejected() {
        for bad in ["", "v", "abc", "1..2", "1.x", "1.-2"] {
            XCTAssertNil(ReleaseVersion(string: bad), bad)
        }
    }

    func testComponentsCompareAsNumbersAndAMissingOneIsZero() {
        XCTAssertEqual(ReleaseVersion(string: "1.7"), ReleaseVersion(string: "1.7.0"))
        XCTAssertTrue(ReleaseVersion(string: "1.0.10")! > ReleaseVersion(string: "1.0.9")!)
        XCTAssertTrue(ReleaseVersion(string: "1.7")! < ReleaseVersion(string: "1.7.1")!)
    }

    // MARK: decide

    func testOnlyAStrictlyNewerReleaseIsAvailable() {
        XCTAssertEqual(UpdateCheck.decide(current: "1.7.0", latest: release("1.8.0")),
                       .available(release("1.8.0")))
        XCTAssertEqual(UpdateCheck.decide(current: "1.7.0", latest: release("1.7.0")), .upToDate)
        XCTAssertEqual(UpdateCheck.decide(current: "1.7.0", latest: release("1.6.9")), .upToDate)
    }

    /// A binary run outside its bundle has no version; it must not be told to
    /// update to whatever is out there.
    func testAnUnparsableCurrentVersionIsUpToDate() {
        XCTAssertEqual(UpdateCheck.decide(current: "", latest: release("1.8.0")), .upToDate)
    }

    // MARK: parse

    func testParsePicksTheDmgAssetAndIgnoresOthers() {
        let parsed = LatestRelease.parse(json(assets: ["MySidepulse-1.8.0.zip", "MySidepulse-1.8.0.dmg"]))
        XCTAssertEqual(parsed, release("1.8.0"))
    }

    func testParseRefusesWhatARealReleaseWouldNotLookLike() {
        XCTAssertNil(LatestRelease.parse(Data("not json".utf8)))
        XCTAssertNil(LatestRelease.parse(json(assets: ["MySidepulse-1.8.0.zip"])), "no DMG")
        XCTAssertNil(LatestRelease.parse(json(tag: nil)), "no tag")
        XCTAssertNil(LatestRelease.parse(json(tag: "nightly")), "a tag that is not a version")
    }

    // MARK: interpret

    func testAReplyIsReadByItsStatusFirst() {
        XCTAssertEqual(UpdateCheck.interpret(status: 200, body: json(), current: "1.7.0"),
                       .success(.available(release("1.8.0"))))
        XCTAssertEqual(UpdateCheck.interpret(status: 200, body: json(), current: "1.8.0"),
                       .success(.upToDate))
        XCTAssertEqual(UpdateCheck.interpret(status: 404, body: Data(), current: "1.7.0"),
                       .success(.noRelease), "no release yet is an answer, not an error")
        XCTAssertEqual(UpdateCheck.interpret(status: 403, body: json(), current: "1.7.0"),
                       .failure(.httpStatus(403)), "a rate limit must not read as up to date")
        XCTAssertEqual(UpdateCheck.interpret(status: 200, body: Data("{}".utf8), current: "1.7.0"),
                       .failure(.malformedResponse))
    }

    func testTheCheckAsksGitHubForThisRepositorysLatestRelease() {
        XCTAssertEqual(UpdateCheck.latestReleaseAPI.absoluteString,
                       "https://api.github.com/repos/bambidotexe/my-sidepulse/releases/latest")
    }

    // MARK: What GitHub says about the file

    func testAReleaseCarriesTheLengthAndTheDigestGitHubStatesForItsDiskImage() throws {
        let body = Data(#"""
        { "tag_name": "v1.8.0", "assets": [ { "name": "MySidepulse-1.8.0.dmg",
          "browser_download_url": "https://example.com/MySidepulse-1.8.0.dmg", "size": 2777987,
          "digest": "sha256:287255244B42ed6affc836ae329832962e69a902a385f75e93a7450800e6b3db" } ] }
        """#.utf8)
        let release = try XCTUnwrap(LatestRelease.parse(body))
        XCTAssertEqual(release.dmgSize, 2_777_987)
        XCTAssertEqual(release.dmgSHA256, "287255244b42ed6affc836ae329832962e69a902a385f75e93a7450800e6b3db",
                       "lowercased: it is compared with a digest this app computes")
    }

    func testAReleaseGitHubSaysNothingMoreAboutIsStillARelease() throws {
        let release = try XCTUnwrap(LatestRelease.parse(json()))
        XCTAssertNil(release.dmgSize)
        XCTAssertNil(release.dmgSHA256)
    }

    func testADigestThatIsNotSHA256IsNotHeldAgainstTheFile() throws {
        let body = Data(#"""
        { "tag_name": "v1.8.0", "assets": [ { "name": "M.dmg", "browser_download_url": "https://example.com/M.dmg",
          "digest": "md5:0123456789abcdef0123456789abcdef" } ] }
        """#.utf8)
        XCTAssertNil(try XCTUnwrap(LatestRelease.parse(body)).dmgSHA256)
    }
}
