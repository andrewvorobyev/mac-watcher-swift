import Foundation
import AppKit
import CaptureSupport
import CoreGraphics

struct ScreenshotMain {
    static func main() {
        autoreleasepool {
            do {
                try run()
            } catch {
                logError("Screenshot failed: \(error)")
                exit(EXIT_FAILURE)
            }
        }
    }

    private static func run() throws {
        let arguments = CommandLine.arguments
        guard arguments.count == 2 else {
            logError("Usage: screenshot <pid>")
            exit(EXIT_FAILURE)
        }

        let pidArgument = arguments[1]
        guard let pidValue = Int32(pidArgument), pidValue > 0 else {
            logError("Invalid process identifier: \(pidArgument)")
            exit(EXIT_FAILURE)
        }

        let pid = pid_t(pidValue)
        let baseName = ProcessUtilities.resolveAppName(for: pid)

        let pngData = try Timing.measure("Captured screenshot") { () throws -> Data in
            guard let window = try primaryWindow(for: pid) else {
                throw ScreenshotError.noVisibleWindows
            }

            guard let image = CGWindowListCreateImage(.null,
                                                      [.optionIncludingWindow],
                                                      window.id,
                                                      [.boundsIgnoreFraming, .bestResolution]) else {
                throw ScreenshotError.captureFailed
            }

            let bitmapRep = NSBitmapImageRep(cgImage: image)
            guard let png = bitmapRep.representation(using: .png, properties: [:]) else {
                throw ScreenshotError.encodingFailed
            }
            return png
        }

        try Timing.measure("Wrote screenshot") {
            let outputDirectory = try ProcessUtilities.outputDirectoryURL()
            let fileURL = outputDirectory.appendingPathComponent("\(baseName)-screenshot.png")
            try pngData.write(to: fileURL, options: .atomic)
            print("Screenshot saved to \(fileURL.path)")
        }
    }

    private static func primaryWindow(for pid: pid_t) throws -> (id: CGWindowID, bounds: CGRect)? {
        guard let infoList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            throw ScreenshotError.windowEnumerationFailed
        }

        var bestCandidate: (id: CGWindowID, bounds: CGRect, area: CGFloat)?

        for info in infoList {
            guard let windowPID = info[kCGWindowOwnerPID as String] as? pid_t, windowPID == pid else {
                continue
            }
            if let isOnscreen = info[kCGWindowIsOnscreen as String] as? Bool, !isOnscreen {
                continue
            }
            if let alpha = info[kCGWindowAlpha as String] as? Double, alpha <= 0 {
                continue
            }
            if let layer = info[kCGWindowLayer as String] as? Int, layer != 0 {
                continue
            }
            guard let windowNumber = info[kCGWindowNumber as String] as? CGWindowID else {
                continue
            }

            guard let boundsAny = info[kCGWindowBounds as String] else {
                continue
            }
            let boundsCF = boundsAny as CFTypeRef
            guard CFGetTypeID(boundsCF) == CFDictionaryGetTypeID() else {
                continue
            }
            let boundsDict = unsafeDowncast(boundsCF as AnyObject, to: CFDictionary.self)
            guard let bounds = CGRect(dictionaryRepresentation: boundsDict), bounds.width > 0, bounds.height > 0 else {
                continue
            }
            let area = bounds.width * bounds.height
            if let current = bestCandidate {
                if area > current.area {
                    bestCandidate = (windowNumber, bounds.integral, area)
                }
            } else {
                bestCandidate = (windowNumber, bounds.integral, area)
            }
        }

        if let best = bestCandidate {
            return (best.id, best.bounds)
        }
        return nil
    }

    private static func logError(_ message: String) {
        fputs(message + "\n", stderr)
    }
}

enum ScreenshotError: Error, CustomStringConvertible {
    case noVisibleWindows
    case windowEnumerationFailed
    case captureFailed
    case encodingFailed

    var description: String {
        switch self {
        case .noVisibleWindows:
            return "No visible windows found for the provided PID."
        case .windowEnumerationFailed:
            return "Unable to enumerate windows for the current display."
        case .captureFailed:
            return "CGWindowListCreateImage returned nil when attempting to capture the window region."
        case .encodingFailed:
            return "Failed to encode captured image as PNG."
        }
    }
}

ScreenshotMain.main()
