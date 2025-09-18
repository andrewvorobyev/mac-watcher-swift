import Foundation

protocol AccessibilityTreeRenderer {
    func render(node: AccessibilityNode) throws -> Data
}

final class YAMLAccessibilityTreeRenderer: AccessibilityTreeRenderer {
    struct Configuration {
        enum Mode {
            case llm(LLMOptions)
            case all
        }

        struct LLMOptions {
            let roleKeys: [String]
            let textKeys: [String]
            let identifierKeys: [String]
            let positionKey: String?
            let sizeKey: String?
            let enabledKeys: [String]
            let focusedKeys: [String]
            let dropGroupRoles: Bool
            let emitEnabledOnlyWhenFalse: Bool
            let emitFocusedOnlyWhenTrue: Bool
        }

        let mode: Mode
        let includeOnlyTextNodesAndAncestors: Bool
        let pruneAttributeLessLeaves: Bool

        static let llm: Configuration = Configuration(
            mode: .llm(
                LLMOptions(
                    roleKeys: ["AXRole"],
                    textKeys: [
                        "AXValue",
                        "AXTitle",
                        "AXLabel",
                        "AXPlaceholderValue",
                        "AXDescription",
                        "AXHelp"
                    ],
                    identifierKeys: ["AXIdentifier"],
                    positionKey: "AXPosition",
                    sizeKey: "AXSize",
                    enabledKeys: ["AXEnabled"],
                    focusedKeys: ["AXFocused"],
                    dropGroupRoles: true,
                    emitEnabledOnlyWhenFalse: true,
                    emitFocusedOnlyWhenTrue: true
                )
            ),
            includeOnlyTextNodesAndAncestors: false,
            pruneAttributeLessLeaves: true
        )

        static let all: Configuration = Configuration(
            mode: .all,
            includeOnlyTextNodesAndAncestors: false,
            pruneAttributeLessLeaves: false
        )

        var requiresAttributeFiltering: Bool {
            switch mode {
            case .all:
                return false
            case .llm:
                return true
            }
        }

        var requiresProcessing: Bool {
            return requiresAttributeFiltering || includeOnlyTextNodesAndAncestors || pruneAttributeLessLeaves
        }
    }

    private let configuration: Configuration

    init(configuration: Configuration) {
        self.configuration = configuration
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
        switch configuration.mode {
        case .all:
            return attributes
        case .llm(let options):
            var result: [String: String] = [:]

            if let role = firstMatch(in: attributes, keys: options.roleKeys), !shouldDrop(role: role, dropGroupRoles: options.dropGroupRoles) {
                result["role"] = role
            }

            if let identifier = firstMatch(in: attributes, keys: options.identifierKeys) {
                result["identifier"] = identifier
            }

            if let text = aggregateText(from: attributes, keys: options.textKeys) {
                result["text"] = text
            }

            if let positionKey = options.positionKey,
               let rawPosition = value(for: positionKey, in: attributes),
               let coordinates = parseNumbers(from: rawPosition, expectedCount: 2) {
                result["x"] = formatNumber(coordinates[0])
                result["y"] = formatNumber(coordinates[1])
            }

            if let sizeKey = options.sizeKey,
               let rawSize = value(for: sizeKey, in: attributes),
               let sizeValues = parseNumbers(from: rawSize, expectedCount: 2) {
                result["width"] = formatNumber(sizeValues[0])
                result["height"] = formatNumber(sizeValues[1])
            }

            if let enabled = booleanValue(in: attributes, keys: options.enabledKeys) {
                if enabled {
                    if !options.emitEnabledOnlyWhenFalse {
                        result["enabled"] = "true"
                    }
                } else {
                    result["enabled"] = "false"
                }
            }

            if let focused = booleanValue(in: attributes, keys: options.focusedKeys) {
                if focused {
                    result["focused"] = "true"
                } else if !options.emitFocusedOnlyWhenTrue {
                    result["focused"] = "false"
                }
            }

            return result
        }
    }

    private func shouldDrop(role: String, dropGroupRoles: Bool) -> Bool {
        guard dropGroupRoles else { return false }
        return role.caseInsensitiveCompare("AXGroup") == .orderedSame || role.caseInsensitiveCompare("group") == .orderedSame
    }

    private func firstMatch(in attributes: [String: String], keys: [String]) -> String? {
        for key in keys {
            if let value = value(for: key, in: attributes) {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    return trimmed
                }
            }
        }
        return nil
    }

    private func value(for key: String, in attributes: [String: String]) -> String? {
        for (attributeKey, value) in attributes {
            if attributeKey.compare(key, options: [.caseInsensitive]) == .orderedSame {
                return value
            }
        }
        return nil
    }

    private func aggregateText(from attributes: [String: String], keys: [String]) -> String? {
        var parts: [String] = []
        for key in keys {
            if let rawValue = value(for: key, in: attributes) {
                let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    parts.append(trimmed)
                }
            }
        }
        guard !parts.isEmpty else { return nil }
        let joined = parts.joined(separator: " ")
        let condensed = joined.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return condensed.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func booleanValue(in attributes: [String: String], keys: [String]) -> Bool? {
        guard let raw = firstMatch(in: attributes, keys: keys) else { return nil }
        return parseBoolean(raw)
    }

    private func parseBoolean(_ value: String) -> Bool? {
        let lowercased = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if ["true", "1", "yes"].contains(lowercased) {
            return true
        }
        if ["false", "0", "no"].contains(lowercased) {
            return false
        }
        return nil
    }

    private func parseNumbers(from string: String, expectedCount: Int) -> [Double]? {
        let pattern = "-?\\d+(?:\\.\\d+)?"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return nil
        }

        let matches = regex.matches(in: string, range: NSRange(string.startIndex..., in: string))
        var values: [Double] = []
        values.reserveCapacity(expectedCount)

        for match in matches {
            guard let range = Range(match.range, in: string) else { continue }
            let substring = String(string[range])
            if let number = Double(substring) {
                values.append(number)
                if values.count == expectedCount {
                    break
                }
            }
        }

        guard values.count == expectedCount else { return nil }
        return values
    }

    private func formatNumber(_ value: Double) -> String {
        let rounded = value.rounded()
        if abs(rounded - value) < 0.0001 {
            return String(Int(rounded))
        }

        var string = String(format: "%.3f", value)
        while string.contains(".") && (string.hasSuffix("0") || string.hasSuffix(".")) {
            string.removeLast()
        }
        return string
    }

    private func nodeContainsText(attributes: [String: String]) -> Bool {
        for (key, value) in attributes {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            let lowerKey = key.lowercased()
            if lowerKey.contains("text") ||
                lowerKey.contains("value") ||
                lowerKey.contains("title") ||
                lowerKey.contains("label") ||
                lowerKey.contains("description") ||
                lowerKey.contains("placeholder") {
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
