import Foundation

/// Posts macOS notifications, as when a pause of Claude sessions or of CI
/// starts or ends, so the owner learns of it without reading the log.
enum Notifier {
    /// The title of the daemon's notifications.
    static let title = "superlinear"

    /// The AppleScript that posts `message`.
    static func script(title: String, message: String) -> String {
        func quoted(_ text: String) -> String {
            "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        return "display notification \(quoted(message)) with title \(quoted(title))"
    }

    /// Posts the notification and does not wait for it. A failure, as with
    /// no one logged in, is only logged.
    static func post(title: String, message: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script(title: title, message: message)]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            print("[superlinear] Could not post a notification: \(error)")
        }
    }
}
