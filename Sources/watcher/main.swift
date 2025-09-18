import Foundation

struct WatcherMain {
    static func main() {
        let arguments = CommandLine.arguments
        guard arguments.count == 2 else {
            logError("Usage: watcher <pid>")
            exit(EXIT_FAILURE)
        }

        let pidArgument = arguments[1]
        guard let pidValue = Int32(pidArgument), pidValue > 0 else {
            logError("Invalid process identifier: \(pidArgument)")
            exit(EXIT_FAILURE)
        }

        let pid = pid_t(pidValue)

        let collector = AccessibilityTreeCollector()
        let renderer: AccessibilityTreeRenderer = XMLAccessibilityTreeRenderer()

        do {
            let tree = try collector.collectTree(for: pid)
            let data = try renderer.render(node: tree)

            let fileURL = try prepareOutputURL(for: pid)
            try data.write(to: fileURL)

            print("Accessibility tree saved to \(fileURL.path)")
        } catch let error as AccessibilityCollectorError {
            logError(error.description)
            exit(EXIT_FAILURE)
        } catch {
            logError("Unexpected error: \(error)")
            exit(EXIT_FAILURE)
        }
    }

    private static func prepareOutputURL(for pid: pid_t) throws -> URL {
        let fileManager = FileManager.default
        let outputDirectory = URL(fileURLWithPath: fileManager.currentDirectoryPath)
            .appendingPathComponent("output", isDirectory: true)

        if !fileManager.fileExists(atPath: outputDirectory.path) {
            try fileManager.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        }

        return outputDirectory.appendingPathComponent("\(pid).xml")
    }

    private static func logError(_ message: String) {
        fputs(message + "\n", stderr)
    }
}

WatcherMain.main()
