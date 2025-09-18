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

        do {
            let tree = try collector.collectTree(for: pid)
            try renderVariants(for: pid, tree: tree)
        } catch let error as AccessibilityCollectorError {
            logError(error.description)
            exit(EXIT_FAILURE)
        } catch {
            logError("Unexpected error: \(error)")
            exit(EXIT_FAILURE)
        }
    }

    private static func renderVariants(for pid: pid_t, tree: AccessibilityNode) throws {
        let variants: [(name: String, configuration: YAMLAccessibilityTreeRenderer.Configuration)] = [
            ("llm", .llm),
            ("all", .all)
        ]

        for (name, configuration) in variants {
            let renderer = YAMLAccessibilityTreeRenderer(configuration: configuration)
            let data = try renderer.render(node: tree)

            let fileURL = try prepareOutputURL(for: pid, variant: name)
            try data.write(to: fileURL)

            print("Accessibility tree (\(name)) saved to \(fileURL.path)")
        }
    }

    private static func prepareOutputURL(for pid: pid_t, variant: String) throws -> URL {
        let fileManager = FileManager.default
        let outputDirectory = URL(fileURLWithPath: fileManager.currentDirectoryPath)
            .appendingPathComponent("output", isDirectory: true)

        if !fileManager.fileExists(atPath: outputDirectory.path) {
            try fileManager.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        }

        return outputDirectory.appendingPathComponent("\(pid)-\(variant).yaml")
    }

    private static func logError(_ message: String) {
        fputs(message + "\n", stderr)
    }
}

WatcherMain.main()
