import Foundation
import AppKit

public enum ProcessUtilities {
    public static func resolveAppName(for pid: pid_t) -> String {
        if let application = NSRunningApplication(processIdentifier: pid),
           let name = application.localizedName,
           let sanitized = sanitizeProcessName(name) {
            return sanitized
        }

        return "pid-\(pid)"
    }

    public static func outputDirectoryURL() throws -> URL {
        let fileManager = FileManager.default
        let outputDirectory = URL(fileURLWithPath: fileManager.currentDirectoryPath)
            .appendingPathComponent("output", isDirectory: true)

        if !fileManager.fileExists(atPath: outputDirectory.path) {
            try fileManager.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        }

        return outputDirectory
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
