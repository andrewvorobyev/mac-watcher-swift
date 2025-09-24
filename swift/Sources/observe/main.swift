import Foundation
import ApplicationServices
import CaptureSupport

struct ObserveMain {
    static func main() {
        let arguments = CommandLine.arguments
        guard arguments.count == 2 else {
            log("Usage: observe <pid>")
            exit(EXIT_FAILURE)
        }

        let pidArgument = arguments[1]
        guard let pidValue = Int32(pidArgument), pidValue > 0 else {
            log("Invalid process identifier: \(pidArgument)")
            exit(EXIT_FAILURE)
        }

        guard AXIsProcessTrusted() else {
            log("Accessibility permissions are required. Grant access in System Settings > Privacy & Security > Accessibility")
            exit(EXIT_FAILURE)
        }

        let pid = pid_t(pidValue)
        let baseName = ProcessUtilities.resolveAppName(for: pid)

        do {
            let outputDirectory = try ProcessUtilities.outputDirectoryURL()
            let logURL = outputDirectory.appendingPathComponent("\(baseName)-obs-log.txt")
            let logger = try AccessibilityEventLogger(logURL: logURL)
            let observer = try AccessibilityProcessObserver(pid: pid, logger: logger)

            try observer.start()
            log("Observing \(baseName) (pid: \(pid)). Logging to \(logURL.path)")
            RunLoop.current.run()
        } catch {
            log("Failed to start observer: \(error)")
            exit(EXIT_FAILURE)
        }
    }

    private static func log(_ message: String) {
        print(message)
    }
}

ObserveMain.main()
