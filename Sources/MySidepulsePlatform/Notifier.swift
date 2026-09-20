import Foundation
import MySidepulseCore

/// Outbound notification push. One POST per alert, retried only briefly: a
/// notification that arrives late is worse than one that never arrives, so
/// the retry budget is small enough that "late" stays inside a few tens of
/// seconds.
public enum Notifier {
    /// ntfy topics are path components, and this one comes out of a config
    /// file rather than out of the program, so it is validated rather than
    /// escaped — a topic that is not a plain word is a mistake, not something
    /// to guess the intent of.
    static func isValidTopic(_ topic: String) -> Bool {
        !topic.isEmpty && topic.count <= 64 && topic.allSatisfy {
            $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_")
        }
    }

    /// The exact request ntfy expects: Title, Tags and Click headers, the
    /// label as body.
    public static func request(server: String, topic: String, title: String, tag: String,
                               click: String, message: String) -> URLRequest? {
        guard isValidTopic(topic),
              let base = URL(string: server),
              let scheme = base.scheme?.lowercased(), scheme == "http" || scheme == "https",
              base.host != nil
        else { return nil }
        var request = URLRequest(url: base.appendingPathComponent(topic))
        request.httpMethod = "POST"
        request.timeoutInterval = K.notifyTimeoutSeconds
        request.setValue(title, forHTTPHeaderField: "Title")
        request.setValue(tag, forHTTPHeaderField: "Tags")
        request.setValue(click, forHTTPHeaderField: "Click")
        request.httpBody = Data(message.utf8)
        return request
    }

    /// The topic is bearer-equivalent — anyone holding it can read the feed —
    /// so it is generated, never derived from anything about the machine.
    public static func generateTopic() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        for i in bytes.indices { bytes[i] = UInt8.random(in: 0...255) }
        return "cc-" + bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// For anywhere the topic is printed without being asked for — doctor
    /// output, logs — since that output gets pasted into issues and
    /// transcripts, and a leaked topic is a burned topic.
    public static func maskTopic(_ topic: String?) -> String {
        guard let topic, !topic.isEmpty else { return "(none)" }
        return String(topic.prefix(6)) + "…"
    }

    /// Fire and forget. Failures are reported for logging and are never fatal.
    ///
    /// A push matters most at the moment the user shuts the lid and walks
    /// off, which is also the moment wifi is mid-reassociation, so a single
    /// POST is not a delivery. Retries are capped and quick — worst case
    /// about `notifyMaxAttempts × (notifyTimeoutSeconds +
    /// notifyRetryDelaySeconds)` — so "never late" stays "never more than
    /// that late".
    ///
    /// Only transient failures qualify. A 4xx is the server saying the request
    /// itself is wrong (a topic that is not a topic, a body it will not take);
    /// sending it again would only be wrong again, and the user is better
    /// served by the failure showing up in the log once.
    public static func send(_ request: URLRequest, session: URLSession = .shared,
                            attemptsLeft: Int = K.notifyMaxAttempts,
                            retryDelay: TimeInterval = K.notifyRetryDelaySeconds,
                            onFailure: @escaping (String) -> Void) {
        session.dataTask(with: request) { _, response, error in
            let failure: String
            let transient: Bool
            if let error {
                failure = error.localizedDescription
                transient = true
            } else if let code = (response as? HTTPURLResponse)?.statusCode, code >= 400 {
                failure = "HTTP \(code)"
                transient = code >= 500 || code == 408 || code == 429
            } else {
                return
            }
            guard transient, attemptsLeft > 1 else {
                onFailure(failure)
                return
            }
            // Reported as it happens rather than only at the end: a push that
            // needed three goes every evening is a wifi problem worth seeing.
            onFailure("\(failure) — retrying (\(attemptsLeft - 1) left)")
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + retryDelay) {
                send(request, session: session, attemptsLeft: attemptsLeft - 1,
                     retryDelay: retryDelay, onFailure: onFailure)
            }
        }.resume()
    }
}

/// `~/.claude/sessions/*.json`: one record per live Claude process, holding
/// both the local session UUID and the bridgeSessionId that claude.ai deep
/// links are keyed by, plus the session's kind.
public enum ClaudeSessions {
    public struct Record: Equatable {
        public let kind: String?
        public let bridgeSessionId: String?
    }

    /// A background, daemon or teammate session is an agent of its own: it
    /// lights the strip but must not ring a phone.
    public static let silentKinds: Set<String> = ["bg", "daemon", "daemon-worker"]

    public static func find(sessionId: String, in directory: URL) -> Record? {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path)
        else { return nil }
        for name in names.sorted() where name.hasSuffix(".json") {
            guard let data = try? Data(contentsOf: directory.appendingPathComponent(name)),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["sessionId"] as? String == sessionId
            else { continue }
            return Record(kind: object["kind"] as? String,
                          bridgeSessionId: object["bridgeSessionId"] as? String)
        }
        return nil
    }

    public static func isSilent(_ record: Record?) -> Bool {
        guard let kind = record?.kind else { return false }
        return silentKinds.contains(kind)
    }

    public static func link(for record: Record?) -> String {
        guard let bridge = record?.bridgeSessionId, !bridge.isEmpty else {
            return "https://claude.ai/code"
        }
        return "https://claude.ai/code/\(bridge)"
    }
}
