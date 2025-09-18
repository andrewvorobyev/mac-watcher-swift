import Foundation

protocol AccessibilityTreeRenderer {
    func render(node: AccessibilityNode) throws -> Data
}

final class YAMLAccessibilityTreeRenderer: AccessibilityTreeRenderer {
    struct Configuration {
        let attributeAllowList: Set<String>?
        let includeOnlyTextNodesAndAncestors: Bool
        let pruneAttributeLessLeaves: Bool
        let dropGroupRoleValues: Bool
        let dropRoleDescriptions: Bool
        let dropSubrole: Bool
        let dropFrameAttributes: Bool
        let emitEnabledOnlyWhenFalse: Bool
        let emitFocusedOnlyWhenTrue: Bool

        static let llm: Configuration = {
            let allowList = Set([
                "axrole",
                "axidentifier",
                "axtitle",
                "axlabel",
                "axvalue",
                "axdescription",
                "axhelp",
                "axplaceholdervalue",
                "axenabled",
                "axfocused",
                "identifier",
                "title",
                "label",
                "value",
                "description",
                "help",
                "placeholder",
                "enabled",
                "focused"
            ].map { $0.lowercased() })

            return Configuration(
                attributeAllowList: allowList,
                includeOnlyTextNodesAndAncestors: false,
                pruneAttributeLessLeaves: true,
                dropGroupRoleValues: true,
                dropRoleDescriptions: true,
                dropSubrole: true,
                dropFrameAttributes: true,
                emitEnabledOnlyWhenFalse: true,
                emitFocusedOnlyWhenTrue: true
            )
        }()

        static let all: Configuration = Configuration(
            attributeAllowList: nil,
            includeOnlyTextNodesAndAncestors: false,
            pruneAttributeLessLeaves: false,
            dropGroupRoleValues: false,
            dropRoleDescriptions: false,
            dropSubrole: false,
            dropFrameAttributes: false,
            emitEnabledOnlyWhenFalse: false,
            emitFocusedOnlyWhenTrue: false
        )

        var requiresAttributeFiltering: Bool {
            attributeAllowList != nil ||
                dropGroupRoleValues ||
                dropRoleDescriptions ||
                dropSubrole ||
                dropFrameAttributes ||
                emitEnabledOnlyWhenFalse ||
                emitFocusedOnlyWhenTrue
        }

        var requiresProcessing: Bool {
            requiresAttributeFiltering ||
                includeOnlyTextNodesAndAncestors ||
                pruneAttributeLessLeaves
        }
    }

    private let configuration: Configuration

    init(configuration: Configuration) {
        if let allowList = configuration.attributeAllowList {
            self.configuration = Configuration(
                attributeAllowList: Set(allowList.map { $0.lowercased() }),
                includeOnlyTextNodesAndAncestors: configuration.includeOnlyTextNodesAndAncestors,
                pruneAttributeLessLeaves: configuration.pruneAttributeLessLeaves,
                dropGroupRoleValues: configuration.dropGroupRoleValues,
                dropRoleDescriptions: configuration.dropRoleDescriptions,
                dropSubrole: configuration.dropSubrole,
                dropFrameAttributes: configuration.dropFrameAttributes,
                emitEnabledOnlyWhenFalse: configuration.emitEnabledOnlyWhenFalse,
                emitFocusedOnlyWhenTrue: configuration.emitFocusedOnlyWhenTrue
            )
        } else {
            self.configuration = configuration
        }
    }

    func render(node: AccessibilityNode) throws -> Data {
        let processedNode: AccessibilityNode
        if configuration.requiresProcessing {
            processedNode = process(node: node) ?? AccessibilityNode(attributes: [:], children: [])
        } else {
            processedNode = node
        }

        let rootValue: YAMLValue = .dictionary([
            "accessibilityTree": nodeValue(processedNode)
        ])
        let lines = serialize(rootValue, indentLevel: 0)
        let yaml = lines.joined(separator: "\n") + "\n"
        return Data(yaml.utf8)
    }

    private func process(node: AccessibilityNode) -> AccessibilityNode? {
        let processedChildren = node.children.compactMap { process(node: $0) }

        let attributes: [String: String]
        if configuration.requiresAttributeFiltering {
            attributes = filterAttributes(node.attributes)
        } else {
            attributes = node.attributes
        }

        if configuration.includeOnlyTextNodesAndAncestors {
            let hasText = nodeContainsText(attributes: attributes)
            if !hasText && processedChildren.isEmpty {
                return nil
            }
        }

        if configuration.pruneAttributeLessLeaves && attributes.isEmpty && processedChildren.isEmpty {
            return nil
        }

        return AccessibilityNode(attributes: attributes, children: processedChildren)
    }

    private func filterAttributes(_ attributes: [String: String]) -> [String: String] {
        var result: [String: String] = [:]

        for (key, value) in attributes {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            let normalizedKey = key.lowercased()

            if let allowList = configuration.attributeAllowList, !allowList.contains(normalizedKey) {
                continue
            }

            if configuration.dropSubrole && (normalizedKey == "axsubrole" || normalizedKey == "subrole") {
                continue
            }

            if configuration.dropRoleDescriptions && (normalizedKey == "axroledescription" || normalizedKey == "roledescription") {
                continue
            }

            if configuration.dropGroupRoleValues && (normalizedKey == "axrole" || normalizedKey == "role") {
                if trimmed.caseInsensitiveCompare("axgroup") == .orderedSame || trimmed.caseInsensitiveCompare("group") == .orderedSame {
                    continue
                }
            }

            if configuration.dropFrameAttributes && (normalizedKey == "axframe" || normalizedKey == "frame") {
                continue
            }

            guard let normalizedValue = normalizeValue(for: normalizedKey, value: trimmed) else {
                continue
            }

            result[key] = normalizedValue
        }

        return result
    }

    private func normalizeValue(for normalizedKey: String, value: String) -> String? {
        if configuration.emitEnabledOnlyWhenFalse && (normalizedKey == "axenabled" || normalizedKey == "enabled") {
            guard let boolValue = parseBoolean(value) else { return nil }
            return boolValue ? nil : "false"
        }

        if configuration.emitFocusedOnlyWhenTrue && (normalizedKey == "axfocused" || normalizedKey == "focused") {
            guard let boolValue = parseBoolean(value) else { return nil }
            return boolValue ? "true" : nil
        }

        return value
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

    private func nodeContainsText(attributes: [String: String]) -> Bool {
        for (key, value) in attributes {
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
