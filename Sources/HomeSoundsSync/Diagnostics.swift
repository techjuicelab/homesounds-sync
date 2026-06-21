import Foundation

/// Lightweight file logger for diagnostics (the unified log was not surfacing
/// NSLog reliably for this ad-hoc app). Writes are dispatched off the audio
/// thread so the render/capture IOProcs never touch the filesystem directly.
enum DBG {
    static let path = "/tmp/hss-debug.log"
    private static let q = DispatchQueue(label: "com.techjuice.homesoundssync.dbg")

    /// Off by default so a published build never writes to /tmp. Enable for
    /// support with `HSS_DEBUG=1 open -W HomeSoundsSync.app` (or the env in Xcode).
    static let enabled = ProcessInfo.processInfo.environment["HSS_DEBUG"] == "1"

    static func reset() {
        guard enabled else { return }
        q.async { FileManager.default.createFile(atPath: path, contents: Data()) }
    }

    static func log(_ s: String) {
        guard enabled else { return }
        q.async {
            guard let data = (s + "\n").data(using: .utf8) else { return }
            if let fh = FileHandle(forWritingAtPath: path) {
                fh.seekToEndOfFile()
                fh.write(data)
                try? fh.close()
            } else {
                FileManager.default.createFile(atPath: path, contents: data)
            }
        }
    }
}
