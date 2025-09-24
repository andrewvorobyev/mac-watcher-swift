import Foundation

final class AccessibilityEventLogger {
    private let fileHandle: FileHandle
    private let queue = DispatchQueue(label: "dev.av.observe.log")
    private let formatter: ISO8601DateFormatter

    init(logURL: URL) throws {
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: logURL.path) {
            fileManager.createFile(atPath: logURL.path, contents: nil, attributes: nil)
        }
        try Data().write(to: logURL, options: .atomic)
        fileHandle = try FileHandle(forWritingTo: logURL)
        formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    }

    deinit {
        fileHandle.closeFile()
    }

    func append(notification: String, details: String?) {
        queue.sync {
            let timestamp = formatter.string(from: Date())
            var line = "[\(timestamp)] \(notification)"
            if let details, !details.isEmpty {
                line += " | \(details)"
            }
            line += "\n"
            if let data = line.data(using: .utf8) {
                fileHandle.seekToEndOfFile()
                fileHandle.write(data)
            }
        }
    }
}
