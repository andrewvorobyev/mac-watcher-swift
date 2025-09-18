import Foundation

protocol AccessibilityTreeRenderer {
    func render(node: AccessibilityNode) throws -> Data
}

final class XMLAccessibilityTreeRenderer: AccessibilityTreeRenderer {
    private let includeOnlyTextNodesAndAncestors: Bool

    init(includeOnlyTextNodesAndAncestors: Bool = false) {
        self.includeOnlyTextNodesAndAncestors = includeOnlyTextNodesAndAncestors
    }

    func render(node: AccessibilityNode) throws -> Data {
        let processedNode: AccessibilityNode
        if includeOnlyTextNodesAndAncestors {
            processedNode = filter(node: node) ?? AccessibilityNode(attributes: [:], children: [])
        } else {
            processedNode = node
        }

        var xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
        xml += render(node: processedNode, indentLevel: 0, isRoot: true)
        return Data(xml.utf8)
    }

    private func render(node: AccessibilityNode, indentLevel: Int, isRoot: Bool) -> String {
        let indent = String(repeating: "  ", count: indentLevel)
        let nodeName = isRoot ? "accessibilityTree" : "node"
        var result = "\(indent)<\(nodeName)>\n"

        if !node.attributes.isEmpty {
            result += "\(indent)  <attributes>\n"
            for key in node.attributes.keys.sorted() {
                let value = escapeXML(node.attributes[key] ?? "")
                result += "\(indent)    <attribute name=\"\(escapeXML(key))\">\(value)</attribute>\n"
            }
            result += "\(indent)  </attributes>\n"
        }

        if !node.children.isEmpty {
            result += "\(indent)  <children>\n"
            for child in node.children {
                result += render(node: child, indentLevel: indentLevel + 2, isRoot: false)
            }
            result += "\(indent)  </children>\n"
        }

        result += "\(indent)</\(nodeName)>\n"
        return result
    }

    private func filter(node: AccessibilityNode) -> AccessibilityNode? {
        let filteredChildren = node.children.compactMap { filter(node: $0) }
        if nodeContainsText(node) || !filteredChildren.isEmpty {
            return AccessibilityNode(attributes: node.attributes, children: filteredChildren)
        }
        return nil
    }

    private func nodeContainsText(_ node: AccessibilityNode) -> Bool {
        for (key, value) in node.attributes {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            let lowerKey = key.lowercased()
            if lowerKey.contains("value") ||
                lowerKey.contains("title") ||
                lowerKey.contains("label") ||
                lowerKey.contains("description") ||
                lowerKey.contains("placeholder") ||
                lowerKey.contains("text") {
                return true
            }
        }
        return false
    }

    private func escapeXML(_ string: String) -> String {
        var escaped = ""
        escaped.reserveCapacity(string.count)
        for character in string {
            switch character {
            case "&":
                escaped.append("&amp;")
            case "\"":
                escaped.append("&quot;")
            case "'":
                escaped.append("&apos;")
            case "<":
                escaped.append("&lt;")
            case ">":
                escaped.append("&gt;")
            default:
                escaped.append(character)
            }
        }
        return escaped
    }
}
