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

final class YAMLAccessibilityTreeRenderer: AccessibilityTreeRenderer {
    func render(node: AccessibilityNode) throws -> Data {
        let rootValue: YAMLValue = .dictionary([
            "accessibilityTree": nodeValue(node)
        ])
        let lines = serialize(rootValue, indentLevel: 0)
        let yaml = lines.joined(separator: "\n") + "\n"
        return Data(yaml.utf8)
    }

    private func nodeValue(_ node: AccessibilityNode) -> YAMLValue {
        var map: [String: YAMLValue] = [:]

        if !node.attributes.isEmpty {
            var attributes: [String: YAMLValue] = [:]
            for key in node.attributes.keys.sorted() {
                attributes[key] = .string(node.attributes[key] ?? "")
            }
            map["attributes"] = .dictionary(attributes)
        }

        if !node.children.isEmpty {
            let values = node.children.map { nodeValue($0) }
            map["children"] = .array(values)
        }

        return .dictionary(map)
    }

    private func serialize(_ value: YAMLValue, indentLevel: Int) -> [String] {
        let indent = String(repeating: "  ", count: indentLevel)

        switch value {
        case .string(let string):
            return ["\(indent)\(formatScalar(string))"]
        case .dictionary(let dictionary):
            guard !dictionary.isEmpty else {
                return ["\(indent){}"]
            }

            var lines: [String] = []
            for key in dictionary.keys.sorted() {
                let escapedKey = formatScalar(key)
                guard let subValue = dictionary[key] else { continue }
                switch subValue {
                case .string(let string):
                    lines.append("\(indent)\(escapedKey): \(formatScalar(string))")
                case .dictionary(let dict):
                    if dict.isEmpty {
                        lines.append("\(indent)\(escapedKey): {}")
                    } else {
                        lines.append("\(indent)\(escapedKey):")
                        lines.append(contentsOf: serialize(.dictionary(dict), indentLevel: indentLevel + 1))
                    }
                case .array(let array):
                    if array.isEmpty {
                        lines.append("\(indent)\(escapedKey): []")
                    } else {
                        lines.append("\(indent)\(escapedKey):")
                        lines.append(contentsOf: serialize(.array(array), indentLevel: indentLevel + 1))
                    }
                }
            }
            return lines
        case .array(let array):
            guard !array.isEmpty else {
                return ["\(indent)[]"]
            }

            var lines: [String] = []
            for element in array {
                switch element {
                case .string(let string):
                    lines.append("\(indent)- \(formatScalar(string))")
                case .dictionary(let dict):
                    if dict.isEmpty {
                        lines.append("\(indent)- {}")
                    } else {
                        lines.append("\(indent)-")
                        lines.append(contentsOf: serialize(.dictionary(dict), indentLevel: indentLevel + 1))
                    }
                case .array(let subArray):
                    if subArray.isEmpty {
                        lines.append("\(indent)- []")
                    } else {
                        lines.append("\(indent)-")
                        lines.append(contentsOf: serialize(.array(subArray), indentLevel: indentLevel + 1))
                    }
                }
            }
            return lines
        }
    }

    private func formatScalar(_ string: String) -> String {
        guard !string.isEmpty else { return "''" }

        if string.allSatisfy({ character in
            character.isLetter || character.isNumber || character == "-" || character == "_" || character == "."
        }) {
            return string
        }

        let escaped = string.replacingOccurrences(of: "'", with: "''")
        return "'\(escaped)'"
    }

    private enum YAMLValue {
        case string(String)
        case dictionary([String: YAMLValue])
        case array([YAMLValue])
    }
}

final class RendererForLLM: AccessibilityTreeRenderer {
    // Focus on semantic details that help an LLM reason about and control UI surfaces.
    private static let defaultAllowedAttributes: Set<String> = [
        "axrole",
        "axsubrole",
        "axroledescription",
        "axidentifier",
        "axtitle",
        "axlabel",
        "axvalue",
        "axdescription",
        "axhelp",
        "axplaceholdervalue",
        "axenabled",
        "axfocused",
        "axframe",
        "role",
        "subrole",
        "identifier",
        "title",
        "label",
        "value",
        "description",
        "help",
        "placeholder",
        "enabled",
        "focused",
        "frame"
    ]

    private let allowedAttributes: Set<String>
    private let yamlRenderer: YAMLAccessibilityTreeRenderer

    init(attributeAllowList: Set<String> = RendererForLLM.defaultAllowedAttributes) {
        self.allowedAttributes = Set(attributeAllowList.map { $0.lowercased() })
        self.yamlRenderer = YAMLAccessibilityTreeRenderer()
    }

    func render(node: AccessibilityNode) throws -> Data {
        let prunedNode = prune(node: node) ?? AccessibilityNode(attributes: [:], children: [])
        return try yamlRenderer.render(node: prunedNode)
    }

    private func prune(node: AccessibilityNode) -> AccessibilityNode? {
        let prunedChildren = node.children.compactMap { prune(node: $0) }

        let filteredAttributes = node.attributes.reduce(into: [String: String]()) { result, attribute in
            let key = attribute.key
            let normalizedKey = key.lowercased()
            guard allowedAttributes.contains(normalizedKey) else { return }

            let trimmedValue = attribute.value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedValue.isEmpty else { return }

            guard let normalizedValue = normalizeAttributeValue(for: normalizedKey, value: trimmedValue) else {
                return
            }

            result[key] = normalizedValue
        }

        let isStructural = !prunedChildren.isEmpty
        if filteredAttributes.isEmpty && !isStructural {
            return nil
        }

        return AccessibilityNode(attributes: filteredAttributes, children: prunedChildren)
    }

    private func normalizeAttributeValue(for normalizedKey: String, value: String) -> String? {
        switch normalizedKey {
        case "axenabled", "enabled":
            guard let boolValue = parseBoolean(value) else { return nil }
            return boolValue ? nil : "false"
        case "axfocused", "focused":
            guard let boolValue = parseBoolean(value) else { return nil }
            return boolValue ? "true" : nil
        case "axframe", "frame":
            return frameCenter(from: value)
        default:
            return value
        }
    }

    private func parseBoolean(_ value: String) -> Bool? {
        let lowercased = value.lowercased()
        if ["true", "1", "yes"].contains(lowercased) {
            return true
        }
        if ["false", "0", "no"].contains(lowercased) {
            return false
        }
        return nil
    }

    private func frameCenter(from value: String) -> String? {
        let pattern = "-?\\d+(?:\\.\\d+)?"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return nil
        }

        let matches = regex.matches(in: value, range: NSRange(value.startIndex..., in: value))
        var numbers: [Double] = []
        numbers.reserveCapacity(matches.count)

        for match in matches {
            guard let range = Range(match.range, in: value) else { continue }
            let substring = String(value[range])
            guard let number = Double(substring) else { continue }
            numbers.append(number)
        }

        guard numbers.count >= 4 else { return nil }

        let originX = numbers[0]
        let originY = numbers[1]
        let width = numbers[2]
        let height = numbers[3]

        let centerX = Int((originX + width / 2.0).rounded())
        let centerY = Int((originY + height / 2.0).rounded())

        return "\(centerX), \(centerY)"
    }
}
