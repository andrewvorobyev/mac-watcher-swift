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
            logError("Usage: snapshot <pid>")
            exit(EXIT_FAILURE)
        }

        let pidArgument = arguments[1]
        guard let pidValue = Int32(pidArgument), pidValue > 0 else {
            logError("Invalid process identifier: \(pidArgument)")
            exit(EXIT_FAILURE)
        }

        let pid = pid_t(pidValue)
        let baseName = ProcessUtilities.resolveAppName(for: pid)

        let windowBounds = try fetchWindowBounds(for: pid)
        guard let captureRect = windowBounds else {
            throw ScreenshotError.noVisibleWindows
        }

        guard let image = CGWindowListCreateImage(captureRect, [.optionOnScreenOnly], kCGNullWindowID, [.bestResolution]) else {
            throw ScreenshotError.captureFailed
        }

        let bitmapRep = NSBitmapImageRep(cgImage: image)
        guard let pngData = bitmapRep.representation(using: .png, properties: [:]) else {
            throw ScreenshotError.encodingFailed
        }

        let outputDirectory = try ProcessUtilities.outputDirectoryURL()
        let fileURL = outputDirectory.appendingPathComponent("\(baseName)-screenshot.png")
        try pngData.write(to: fileURL, options: .atomic)

        print("Screenshot saved to \(fileURL.path)")
    }

    private static func fetchWindowBounds(for pid: pid_t) throws -> CGRect? {
        guard let infoList = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else {
            throw ScreenshotError.windowEnumerationFailed
        }

        var unionRect = CGRect.null
        for info in infoList {
            guard let windowPID = info[kCGWindowOwnerPID as String] as? pid_t, windowPID == pid else {
                continue
            }
            guard let boundsAny = info[kCGWindowBounds as String] else {
                continue
            }

            let boundsCF = boundsAny as CFTypeRef
            guard CFGetTypeID(boundsCF) == CFDictionaryGetTypeID() else {
                continue
            }

            let boundsDict = unsafeBitCast(boundsCF, to: CFDictionary.self)
            guard let bounds = CGRect(dictionaryRepresentation: boundsDict) else {
                continue
            }
            if unionRect.isNull {
                unionRect = bounds
            } else {
                unionRect = unionRect.union(bounds)
            }
        }

        return unionRect.isNull ? nil : unionRect.integral
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
