import Foundation
@preconcurrency import ApplicationServices

enum AccessibilityObservationError: Error, CustomStringConvertible {
    case observerCreationFailed(AXError)
    case addNotificationFailed(String, AXError)
    case runLoopSourceMissing

    var description: String {
        switch self {
        case .observerCreationFailed(let error):
            return "Failed to create AXObserver (error: \(error.rawValue))"
        case .addNotificationFailed(let name, let error):
            return "Failed to subscribe to notification \(name) (error: \(error.rawValue))"
        case .runLoopSourceMissing:
            return "Observer run loop source unavailable"
        }
    }
}

final class AccessibilityProcessObserver {

    private let pid: pid_t
    private let logger: AccessibilityEventLogger
    private let observer: AXObserver
    private let applicationElement: AXUIElement
    private var runLoopSource: CFRunLoopSource?
    private var subscribedNotifications: [CFString] = []

    private let notifications: [CFString] = [
        kAXFocusedUIElementChangedNotification as CFString,
        kAXTitleChangedNotification as CFString,
        kAXWindowCreatedNotification as CFString,
        kAXWindowMovedNotification as CFString,
        kAXWindowResizedNotification as CFString,
        kAXUIElementDestroyedNotification as CFString,
        kAXValueChangedNotification as CFString
    ]

    init(pid: pid_t, logger: AccessibilityEventLogger) throws {
        self.pid = pid
        self.logger = logger
        self.applicationElement = AXUIElementCreateApplication(pid)

        var observerRef: AXObserver?
        let error = AXObserverCreate(pid, AccessibilityProcessObserver.observerCallback, &observerRef)
        guard error == .success, let observerRef else {
            throw AccessibilityObservationError.observerCreationFailed(error)
        }
        self.observer = observerRef
    }

    func start() throws {
        let selfPointer = Unmanaged.passUnretained(self).toOpaque()

        for notification in notifications {
            let status = AXObserverAddNotification(observer, applicationElement, notification, selfPointer)
            switch status {
            case .success:
                subscribedNotifications.append(notification)
            case .notificationUnsupported:
                logger.append(notification: "observe.warning", details: "Notification \(notification) unsupported")
            default:
                logger.append(notification: "observe.error", details: "Failed to subscribe \(notification) (error: \(status.rawValue))")
            }
        }

        guard !subscribedNotifications.isEmpty else {
            throw AccessibilityObservationError.addNotificationFailed("none", .notificationUnsupported)
        }

        let sourceOptional: CFRunLoopSource! = AXObserverGetRunLoopSource(observer)
        guard let source = sourceOptional else {
            throw AccessibilityObservationError.runLoopSourceMissing
        }
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .defaultMode)
    }

    deinit {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .defaultMode)
        }

        for notification in subscribedNotifications {
            AXObserverRemoveNotification(observer, applicationElement, notification)
        }
    }

    private func handle(notification: CFString, element: AXUIElement) {
        var details: [String] = []
        if let role = copyAttribute(element: element, attribute: kAXRoleAttribute as CFString) {
            details.append("role=\(role)")
        }
        if let identifier = copyAttribute(element: element, attribute: kAXIdentifierAttribute as CFString) {
            details.append("id=\(identifier)")
        }

        if let title = normalizedAttribute(element: element, attribute: kAXTitleAttribute as CFString) {
            details.append("title=\(title)")
        }

        if let value = normalizedAttribute(element: element, attribute: kAXValueAttribute as CFString) {
            details.append("value=\(value)")
        }

        if let description = normalizedAttribute(element: element, attribute: kAXDescriptionAttribute as CFString) {
            details.append("description=\(description)")
        }

        logger.append(notification: notification as String,
                      details: details.isEmpty ? nil : details.joined(separator: ", "))
    }

    private func normalizedAttribute(element: AXUIElement, attribute: CFString) -> String? {
        guard let raw = copyAttribute(element: element, attribute: attribute) else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func copyAttribute(element: AXUIElement, attribute: CFString) -> String? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute, &value)
        guard error == .success, let unwrapped = value else { return nil }

        if CFGetTypeID(unwrapped) == AXValueGetTypeID() {
            return String(describing: unwrapped)
        }
        if let attributed = unwrapped as? NSAttributedString {
            return attributed.string
        }
        return (unwrapped as AnyObject) as? String ?? String(describing: unwrapped)
    }

    private static let observerCallback: AXObserverCallback = { _, element, notification, refcon in
        guard let refcon else { return }
        let observerSelf = Unmanaged<AccessibilityProcessObserver>.fromOpaque(refcon).takeUnretainedValue()
        observerSelf.handle(notification: notification, element: element)
    }
}
