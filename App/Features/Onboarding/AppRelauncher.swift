import AppKit
import Foundation

@MainActor
enum AppRelauncher {
    static func relaunch() {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/open")
        // Forward launch arguments so a dev relaunch keeps its fixture root and dry run flags.
        let forwarded = Array(ProcessInfo.processInfo.arguments.dropFirst())
        process.arguments = ["-n", Bundle.main.bundleURL.path(percentEncoded: false)]
            + (forwarded.isEmpty ? [] : ["--args"] + forwarded)
        do {
            try process.run()
            for window in NSApp.windows {
                if let sheet = window.attachedSheet {
                    window.endSheet(sheet)
                }
            }
            NSApp.terminate(nil)
        } catch {
            NSSound.beep()
        }
    }
}
