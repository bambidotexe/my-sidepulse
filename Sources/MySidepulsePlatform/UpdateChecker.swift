import CryptoKit
import Foundation
import MySidepulseCore

/// The only code that talks to GitHub: the latest release, asked shortly after
/// launch, weekly after that and when the settings button is pressed, and that
/// release's disk image, fetched only after a click on Update. Completions run
/// on the session's queue, not on main.
public enum UpdateChecker {
    /// `MYSIDEPULSE_UPDATE_FEED` points a build at a stand-in for GitHub's
    /// reply: a `file://` or `http://` URL of a latest-release JSON, whose
    /// `browser_download_url` may be a `file://` URL too. It is how the whole
    /// update is exercised without publishing a release.
    public static var feedURL: URL {
        ProcessInfo.processInfo.environment["MYSIDEPULSE_UPDATE_FEED"].flatMap(URL.init(string:))
            ?? UpdateCheck.latestReleaseAPI
    }

    /// Anonymous, so it only ever sees a public repository's releases.
    public static func check(current: String, session: URLSession = .shared,
                             completion: @escaping (Result<UpdateDecision, Error>) -> Void) {
        var request = URLRequest(url: feedURL,
                                 cachePolicy: .reloadIgnoringLocalCacheData,
                                 timeoutInterval: K.updateCheckTimeoutSeconds)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        session.dataTask(with: request) { data, response, error in
            if let error { return completion(.failure(error)) }
            // A stand-in feed read from a file has no status: it is the reply.
            let status = (response as? HTTPURLResponse)?.statusCode ?? 200
            completion(UpdateCheck.interpret(status: status, body: data ?? Data(), current: current)
                .mapError { $0 as Error })
        }.resume()
    }
}

/// One fetch of a release's disk image, reporting its progress. The finished
/// file is held against what GitHub said about the asset (its length, its
/// SHA-256) before anyone is told it is there: a download cut short or altered
/// on the way never reaches the disk image tools. Both closures run on the
/// session's queue; after `cancel()` neither runs again.
public final class UpdateDownload: NSObject, URLSessionDownloadDelegate {
    public enum Failure: Error, Equatable {
        /// The file is not the one GitHub described.
        case damaged
    }

    private let release: LatestRelease
    private let destination: URL
    private let configuration: URLSessionConfiguration
    private let onProgress: (Int64, Int64) -> Void
    private let onDone: (Result<URL, Error>) -> Void
    private let lock = NSLock()
    private var session: URLSession?
    private var ended = false

    /// `destination` is the file the image is written as; a file already there
    /// is replaced.
    public init(release: LatestRelease, destination: URL,
                configuration: URLSessionConfiguration = .ephemeral,
                onProgress: @escaping (Int64, Int64) -> Void,
                onDone: @escaping (Result<URL, Error>) -> Void) {
        self.release = release
        self.destination = destination
        self.configuration = configuration
        self.onProgress = onProgress
        self.onDone = onDone
    }

    public func start() {
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        lock.withLock { self.session = session }
        session.downloadTask(with: release.dmgURL).resume()
    }

    public func cancel() { claimEnd()?.invalidateAndCancel() }

    /// The session, for the first caller only: a download ends once, by
    /// finishing, failing or being cancelled.
    private func claimEnd() -> URLSession? {
        lock.withLock {
            guard !ended else { return nil }
            ended = true
            return session
        }
    }

    private func end(_ result: Result<URL, Error>) {
        guard let session = claimEnd() else { return }
        session.finishTasksAndInvalidate()
        onDone(result)
    }

    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                           didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                           totalBytesExpectedToWrite: Int64) {
        guard !lock.withLock({ ended }) else { return }
        onProgress(totalBytesWritten, totalBytesExpectedToWrite)
    }

    /// The temporary file is gone once this returns, so it is moved and
    /// checked here.
    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                           didFinishDownloadingTo location: URL) {
        do {
            // A download task "succeeds" on a 404 and hands over the error
            // page; opening that as a disk image helps nobody.
            if let status = (downloadTask.response as? HTTPURLResponse)?.statusCode,
               !(200...299).contains(status) {
                throw UpdateFailure.httpStatus(status)
            }
            let files = FileManager.default
            try files.createDirectory(at: destination.deletingLastPathComponent(),
                                      withIntermediateDirectories: true)
            try? files.removeItem(at: destination)
            try files.moveItem(at: location, to: destination)
            guard try Self.matches(release, file: destination) else {
                try? files.removeItem(at: destination)
                throw Failure.damaged
            }
            end(.success(destination))
        } catch {
            end(.failure(error))
        }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { end(.failure(error)) }
    }

    /// Whatever GitHub stated about the asset has to hold; what it did not
    /// state is not held against the file.
    static func matches(_ release: LatestRelease, file: URL) throws -> Bool {
        if let size = release.dmgSize {
            let actual = try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber
            guard actual?.int64Value == size else { return false }
        }
        guard let expected = release.dmgSHA256 else { return true }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = CryptoKit.SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hex(hasher.finalize()) == expected
    }

    static func sha256(of data: Data) -> String { hex(CryptoKit.SHA256.hash(data: data)) }

    private static func hex(_ digest: CryptoKit.SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}
