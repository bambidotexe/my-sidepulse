import XCTest

final class PurityTests: XCTestCase {
    /// MySidepulseCore is the pure brain: Foundation only. If this fails, a
    /// framework import leaked into the rules — move the code to Platform/App.
    func testCoreImportsOnlyFoundation() throws {
        let here = URL(fileURLWithPath: #filePath)
        let repoRoot = here.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let coreDir = repoRoot.appendingPathComponent("Sources/MySidepulseCore")
        let files = try FileManager.default.contentsOfDirectory(at: coreDir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        XCTAssertFalse(files.isEmpty, "no Core sources found — wrong path?")
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for rawLine in text.split(separator: "\n") {
                let line = rawLine.trimmingCharacters(in: .whitespaces)
                guard line.hasPrefix("import ") else { continue }
                let module = String(line.dropFirst("import ".count))
                XCTAssertEqual(module, "Foundation",
                    "\(file.lastPathComponent) imports \(module); Core may import Foundation only")
            }
        }
    }
}
