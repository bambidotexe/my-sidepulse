import Foundation

/// Reading and writing Claude Code's settings.json. Strict on purpose: this
/// file belongs to the user and holds configuration this project knows
/// nothing about, so every ambiguous case is an error rather than a guess.
public enum SettingsFile {
    public enum Failure: Error, CustomStringConvertible {
        case unreadable(String)
        case unparseable
        case backupFailed(String)
        case writeFailed(String)

        public var description: String {
            switch self {
            case .unreadable(let why): return "could not read settings: \(why)"
            case .unparseable: return "settings file exists but is not valid JSON; refusing to touch it"
            case .backupFailed(let why): return "could not write a backup: \(why)"
            case .writeFailed(let why): return "could not write settings: \(why)"
            }
        }
    }

    /// nil when the file does not exist. Throws when it exists but cannot be
    /// read or parsed — never silently returns an empty config, which would
    /// discard everything the user has configured.
    public static func load(at path: URL) throws -> [String: Any]? {
        guard FileManager.default.fileExists(atPath: path.path) else { return nil }
        let data: Data
        do { data = try Data(contentsOf: path) }
        catch { throw Failure.unreadable(error.localizedDescription) }
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw Failure.unparseable
        }
        return root
    }

    /// Copy the live file aside before it is touched. If it exists and the
    /// copy fails, that is a hard error: without a backup, a mistake here is
    /// unrecoverable.
    public static func backup(from path: URL, to backupPath: URL) throws {
        guard FileManager.default.fileExists(atPath: path.path) else { return }
        try? FileManager.default.removeItem(at: backupPath)
        do { try FileManager.default.copyItem(at: path, to: backupPath) }
        catch { throw Failure.backupFailed(error.localizedDescription) }
    }

    public static func write(_ root: [String: Any], to path: URL) throws {
        do {
            let data = try JSONSerialization.data(withJSONObject: root,
                                                  options: [.prettyPrinted, .sortedKeys])
            try FileManager.default.createDirectory(at: path.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try data.write(to: path, options: .atomic)
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Failure.writeFailed(error.localizedDescription)
        }
    }
}
