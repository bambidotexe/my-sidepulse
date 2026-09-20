import Foundation

/// A dotted version ("1.7.0", optionally "v1.7.0"), compared numerically per
/// component. A missing trailing component counts as 0, so "1.7" == "1.7.0",
/// and "1.0.10" > "1.0.9".
public struct ReleaseVersion: Comparable, Equatable {
    let components: [Int]

    public init(_ major: Int, _ minor: Int, _ patch: Int) { components = [major, minor, patch] }

    /// nil for an empty string or one with a non-numeric component.
    public init?(string: String) {
        var s = Substring(string)
        if s.first == "v" { s = s.dropFirst() }
        guard !s.isEmpty else { return nil }
        var parsed: [Int] = []
        for part in s.split(separator: ".", omittingEmptySubsequences: false) {
            guard let n = Int(part), n >= 0 else { return nil }
            parsed.append(n)
        }
        components = parsed
    }

    /// "1.7.0", as parsed: no "v", not padded.
    public var displayString: String { components.map(String.init).joined(separator: ".") }

    public static func == (lhs: ReleaseVersion, rhs: ReleaseVersion) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        return lhs.padded(to: count) == rhs.padded(to: count)
    }

    public static func < (lhs: ReleaseVersion, rhs: ReleaseVersion) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        return lhs.padded(to: count).lexicographicallyPrecedes(rhs.padded(to: count))
    }

    private func padded(to count: Int) -> [Int] {
        components + Array(repeating: 0, count: max(0, count - components.count))
    }
}

/// GitHub's `/releases/latest` reply, reduced to what the app needs. This is
/// the contract a release has to meet: a tag that parses as a version, and one
/// asset whose name ends in ".dmg".
///
/// The asset's length and SHA-256 are GitHub's own statement about the file it
/// serves. The length sizes the progress bar when the download's response
/// carries none, and a finished download is held against both before anything
/// opens it.
public struct LatestRelease: Equatable {
    public let version: ReleaseVersion
    public let dmgURL: URL
    public let dmgSize: Int64?
    /// 64 lowercase hex digits, or nil when GitHub states no SHA-256 for the
    /// asset.
    public let dmgSHA256: String?

    public init(version: ReleaseVersion, dmgURL: URL, dmgSize: Int64? = nil,
                dmgSHA256: String? = nil) {
        self.version = version
        self.dmgURL = dmgURL
        self.dmgSize = dmgSize
        self.dmgSHA256 = dmgSHA256
    }

    private struct DTO: Decodable {
        struct Asset: Decodable {
            let name: String
            let browser_download_url: String
            let size: Int64?
            let digest: String?
        }
        let tag_name: String?
        let assets: [Asset]?
    }

    /// nil on malformed JSON, a missing or unparsable `tag_name`, or no asset
    /// ending in ".dmg".
    public static func parse(_ data: Data) -> LatestRelease? {
        guard let dto = try? JSONDecoder().decode(DTO.self, from: data),
              let tag = dto.tag_name, let version = ReleaseVersion(string: tag),
              let dmg = dto.assets?.first(where: { $0.name.hasSuffix(".dmg") }),
              let url = URL(string: dmg.browser_download_url)
        else { return nil }
        return LatestRelease(version: version, dmgURL: url,
                             dmgSize: dmg.size.flatMap { $0 > 0 ? $0 : nil },
                             dmgSHA256: sha256(in: dmg.digest))
    }

    /// GitHub writes an asset's digest as "sha256:<hex>".
    private static func sha256(in digest: String?) -> String? {
        guard let digest, digest.hasPrefix("sha256:") else { return nil }
        let hex = digest.dropFirst("sha256:".count).lowercased()
        guard hex.count == 64, hex.allSatisfy(\.isHexDigit) else { return nil }
        return hex
    }
}

public enum UpdateDecision: Equatable {
    case upToDate
    case available(LatestRelease)
    /// GitHub has nothing to compare with.
    case noRelease
}

public enum UpdateFailure: LocalizedError, Equatable {
    case httpStatus(Int)
    case malformedResponse

    public var errorDescription: String? {
        switch self {
        case .httpStatus(let code): return Loc.update.httpStatus(code)
        case .malformedResponse: return Loc.update.malformedResponse
        }
    }
}

/// The update check against GitHub releases: what to ask, and what the answer
/// means. The request itself is `UpdateChecker`'s, and when it is made without
/// being asked for is `UpdateSchedule`'s.
public enum UpdateCheck {
    public static let latestReleaseAPI =
        URL(string: "https://api.github.com/repos/bambidotexe/my-sidepulse/releases/latest")!

    /// `available` only when `latest` is strictly newer than `current`. An
    /// equal or older release, or a `current` that does not parse (a binary
    /// run outside its bundle has no version), is `upToDate`.
    public static func decide(current: String, latest: LatestRelease) -> UpdateDecision {
        guard let currentVersion = ReleaseVersion(string: current),
              latest.version > currentVersion else { return .upToDate }
        return .available(latest)
    }

    /// What one reply from `latestReleaseAPI` means. 404 is GitHub's answer
    /// for a repository without a release — and for one it does not show to
    /// an anonymous caller, which it does not tell apart.
    public static func interpret(status: Int, body: Data,
                                 current: String) -> Result<UpdateDecision, UpdateFailure> {
        if status == 404 { return .success(.noRelease) }
        guard (200...299).contains(status) else { return .failure(.httpStatus(status)) }
        guard let latest = LatestRelease.parse(body) else { return .failure(.malformedResponse) }
        return .success(decide(current: current, latest: latest))
    }
}
