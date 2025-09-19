import Foundation
import AppKit
import CaptureSupport

@main
struct CaptureMain {
    static func main() {
        let arguments = CommandLine.arguments
        guard arguments.count == 2 else {
            logError("Usage: capture <pid>")
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

        let baseName = ProcessUtilities.resolveAppName(for: pid)

        for (name, configuration) in variants {
            let collector = AccessibilityTreeCollector(configuration: configuration)

            let tree = try Timing.measure("Captured accessibility tree (\(name))") {
                try collector.collectTree(for: pid)
            }

            for rendererDescriptor in renderers {
                let renderer = rendererDescriptor.makeRenderer(configuration)

                let outputVariant = name + rendererDescriptor.suffix

                let data = try Timing.measure("Rendered accessibility tree (\(outputVariant))") {
                    try renderer.render(node: tree)
                }

                let fileURL = try prepareOutputURL(baseName: baseName, variant: outputVariant, fileExtension: rendererDescriptor.fileExtension)
                try data.write(to: fileURL)

                print("Accessibility tree (\(outputVariant)) saved to \(fileURL.path)")
            }
        }
    }

    private static func prepareOutputURL(baseName: String, variant: String, fileExtension: String) throws -> URL {
        let outputDirectory = try ProcessUtilities.outputDirectoryURL()
        return outputDirectory.appendingPathComponent("\(baseName)-\(variant).\(fileExtension)")
    }

    private static func logError(_ message: String) {
        fputs(message + "\n", stderr)
    }

}

private struct RendererDescriptor {
    let suffix: String
    let fileExtension: String
    let makeRenderer: (AccessibilityTreeConfiguration) -> AccessibilityTreeRenderer
}
