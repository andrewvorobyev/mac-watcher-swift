import Foundation
import AppKit

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

        do {
            try renderVariants(for: pid)
        } catch let error as AccessibilityCollectorError {
            logError(error.description)
            exit(EXIT_FAILURE)
        } catch {
            logError("Unexpected error: \(error)")
            exit(EXIT_FAILURE)
        }
    }

    private static func renderVariants(for pid: pid_t) throws {
        let variants: [(name: String, configuration: AccessibilityTreeConfiguration)] = [
            ("llm", .llm),
            ("all", .all)
        ]

        let renderers: [RendererDescriptor] = [
            RendererDescriptor(suffix: "", fileExtension: "yaml", makeRenderer: { YAMLAccessibilityTreeRenderer(configuration: $0) }),
            RendererDescriptor(suffix: "", fileExtension: "json", makeRenderer: { JSONAccessibilityTreeRenderer(configuration: $0, style: .pretty) }),
            RendererDescriptor(suffix: ".min", fileExtension: "json", makeRenderer: { JSONAccessibilityTreeRenderer(configuration: $0, style: .compact) })
        ]

        let baseName = resolveAppName(for: pid)

        for (name, configuration) in variants {
            let collector = AccessibilityTreeCollector(configuration: configuration)

            let captureStart = Date()
            let tree = try collector.collectTree(for: pid)
            let captureDuration = Date().timeIntervalSince(captureStart)
            print(String(format: "Captured accessibility tree (%@) in %.3f s", name, captureDuration))

            for rendererDescriptor in renderers {
                let renderer = rendererDescriptor.makeRenderer(configuration)

                let renderStart = Date()
                let data = try renderer.render(node: tree)
                let renderDuration = Date().timeIntervalSince(renderStart)
                let outputVariant = name + rendererDescriptor.suffix
                print(String(format: "Rendered accessibility tree (%@) in %.3f s", outputVariant, renderDuration))

                let fileURL = try prepareOutputURL(baseName: baseName, variant: outputVariant, fileExtension: rendererDescriptor.fileExtension)
                try data.write(to: fileURL)

                print("Accessibility tree (\(outputVariant)) saved to \(fileURL.path)")
            }
        }
    }

    private static func prepareOutputURL(baseName: String, variant: String, fileExtension: String) throws -> URL {
        let fileManager = FileManager.default
        let outputDirectory = URL(fileURLWithPath: fileManager.currentDirectoryPath)
            .appendingPathComponent("output", isDirectory: true)

        if !fileManager.fileExists(atPath: outputDirectory.path) {
            try fileManager.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        }

        return outputDirectory.appendingPathComponent("\(baseName)-\(variant).\(fileExtension)")
    }

    private static func logError(_ message: String) {
        fputs(message + "\n", stderr)
    }

    private static func resolveAppName(for pid: pid_t) -> String {
        if let application = NSRunningApplication(processIdentifier: pid),
           let name = application.localizedName,
           let sanitized = sanitizeProcessName(name) {
            return sanitized
        }

        return "pid-\(pid)"
    }

    private static func sanitizeProcessName(_ name: String) -> String? {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let components = name
            .lowercased()
            .components(separatedBy: allowed.inverted)
            .filter { !$0.isEmpty }

        guard !components.isEmpty else { return nil }
        return components.joined(separator: "-")
    }
}

private struct RendererDescriptor {
    let suffix: String
    let fileExtension: String
    let makeRenderer: (AccessibilityTreeConfiguration) -> AccessibilityTreeRenderer
}

WatcherMain.main()
