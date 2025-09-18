import Foundation
import ApplicationServices

struct AccessibilityNode {
    let attributes: [String: String]
    let children: [AccessibilityNode]
}

enum AccessibilityCollectorError: Error, CustomStringConvertible {
    case accessibilityPermissionMissing
    case axError(AXError)

    var description: String {
        switch self {
        case .accessibilityPermissionMissing:
            return "Accessibility permissions are not granted. Grant permissions in System Settings > Privacy & Security > Accessibility."
        case .axError(let error):
            return "AXError: \(error)"
        }
    }
}

final class AccessibilityTreeCollector {
    func collectTree(for pid: pid_t) throws -> AccessibilityNode {
        guard AXIsProcessTrusted() else {
            throw AccessibilityCollectorError.accessibilityPermissionMissing
        }

        let appElement = AXUIElementCreateApplication(pid)
        var visited: Set<AXElementID> = []
        return buildNode(from: appElement, visited: &visited)
    }

    private func buildNode(from element: AXUIElement, visited: inout Set<AXElementID>) -> AccessibilityNode {
        let identifier = AXElementID(element: element)
        if visited.contains(identifier) {
            return AccessibilityNode(attributes: ["cycle": "true"], children: [])
        }
        visited.insert(identifier)

        var attributes: [String: String] = [:]

        var attributeNamesCF: CFArray?
        let namesError = AXUIElementCopyAttributeNames(element, &attributeNamesCF)
        let attributeNames: [String]
        switch namesError {
        case .success:
            attributeNames = attributeNamesCF as? [String] ?? []
        case .attributeUnsupported:
            attributeNames = []
        default:
            attributes["error.attributeNames"] = "AXError: \(namesError)"
            visited.remove(identifier)
            return AccessibilityNode(attributes: attributes, children: [])
        }

        var children: [AccessibilityNode] = []

        for name in attributeNames {
            if name == kAXChildrenAttribute as String {
                switch copyChildren(from: element, visited: &visited) {
                case .success(let childNodes):
                    children.append(contentsOf: childNodes)
                case .failure(let error):
                    attributes["error.children"] = error.description
                }
                continue
            }

            switch copyAttributeValue(element: element, attribute: name) {
            case .success(let value):
                if let value {
                    attributes[name] = value
                }
            case .failure(let error):
                attributes["error.attribute.\(name)"] = error.description
            }
        }

        return AccessibilityNode(attributes: attributes, children: children)
    }

    private func copyChildren(from element: AXUIElement, visited: inout Set<AXElementID>) -> Result<[AccessibilityNode], AccessibilityCollectorError> {
        var childrenCF: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenCF)
        if error == .attributeUnsupported {
            return .success([])
        }
        if error != .success {
            return .failure(.axError(error))
        }

        guard let array = childrenCF as? [AXUIElement] else {
            return .success([])
        }

        var result: [AccessibilityNode] = []
        result.reserveCapacity(array.count)

        for child in array {
            let node = buildNode(from: child, visited: &visited)
            result.append(node)
        }

        return .success(result)
    }

    private func copyAttributeValue(element: AXUIElement, attribute: String) -> Result<String?, AccessibilityCollectorError> {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        switch error {
        case .success:
            break
        case .attributeUnsupported:
            return .success(nil)
        default:
            return .failure(.axError(error))
        }

        guard let unwrapped = value else {
            return .success(nil)
        }

        return .success(stringify(unwrapped))
    }

    private func stringify(_ value: CFTypeRef) -> String {
        let anyValue = value as Any

        if let string = anyValue as? String {
            return string
        }
        if let number = anyValue as? NSNumber {
            // NSNumber can represent Bool internally.
            if CFGetTypeID(value) == CFBooleanGetTypeID() {
                return number.boolValue ? "true" : "false"
            } else {
                return number.stringValue
            }
        }
        if let array = anyValue as? [Any] {
            let stringValues = array.map { element -> String in
                let cfValue = element as CFTypeRef
                return stringify(cfValue)
            }
            return "[" + stringValues.joined(separator: ", ") + "]"
        }
        if let dict = anyValue as? [AnyHashable: Any] {
            let stringValues = dict.map { key, value -> String in
                let valueString = stringify(value as CFTypeRef)
                return "\(key): \(valueString)"
            }.sorted()
            return "{" + stringValues.joined(separator: ", ") + "}"
        }
        if CFGetTypeID(value) == AXUIElementGetTypeID() {
            return "AXUIElement"
        }

        return String(describing: anyValue)
    }
}

private struct AXElementID: Hashable {
    private let element: AXUIElement

    init(element: AXUIElement) {
        self.element = element
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(CFHash(element))
    }

    static func == (lhs: AXElementID, rhs: AXElementID) -> Bool {
        CFEqual(lhs.element, rhs.element)
    }
}
