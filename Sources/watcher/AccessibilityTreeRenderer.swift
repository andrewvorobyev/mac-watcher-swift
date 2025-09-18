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
        let stripAttributesFromStructureNodes: Bool

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
            pruneAttributeLessLeaves: true,
            stripAttributesFromStructureNodes: true
        )

        static let all: Configuration = Configuration(
            mode: .all,
            includeOnlyTextNodesAndAncestors: false,
            pruneAttributeLessLeaves: false,
            stripAttributesFromStructureNodes: false
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
            return requiresAttributeFiltering || includeOnlyTextNodesAndAncestors || pruneAttributeLessLeaves || stripAttributesFromStructureNodes
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
            "accessibilityTree": nodeValue(processedNode, configuration: configuration)
        ])
        let lines = serialize(rootValue, indentLevel: 0)
        let yaml = lines.joined(separator: "\n") + "\n"
        return Data(yaml.utf8)
    }

    private func process(node: AccessibilityNode) -> AccessibilityNode? {
        let processedChildren = node.children.compactMap { process(node: $0) }

        var attributes: [String: String]
        if configuration.requiresAttributeFiltering {
            attributes = filterAttributes(node.attributes)
        } else {
            attributes = node.attributes
        }

        if configuration.stripAttributesFromStructureNodes && isStructureNode(attributes: attributes) {
            attributes = [:]
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
                result["text"] = summarizeText(text)
            }

            if let positionKey = options.positionKey,
               let rawPosition = value(for: positionKey, in: attributes),
               let coordinates = parseNamedValues(["x", "y"], from: rawPosition) {
                result["x"] = formatNumber(coordinates[0])
                result["y"] = formatNumber(coordinates[1])
            }

            if let sizeKey = options.sizeKey,
               let rawSize = value(for: sizeKey, in: attributes),
               let sizeValues = parseNamedValues(["w", "h"], from: rawSize) {
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
        return condenseWhitespace(in: joined)
    }

    private func summarizeText(_ text: String) -> String {
        let condensed = condenseWhitespace(in: text)
        let limit = 180
        guard condensed.count > limit else { return condensed }

        let index = condensed.index(condensed.startIndex, offsetBy: limit)
        var snippet = String(condensed[..<index])
        snippet = snippet.trimmingCharacters(in: .whitespacesAndNewlines)
        let remaining = max(condensed.count - snippet.count, 0)

        if remaining == 0 {
            return snippet
        }

        return "\(snippet)… (+\(remaining) chars)"
    }

    private func condenseWhitespace(in text: String) -> String {
        let condensed = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
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

    private func parseNamedValues(_ keys: [String], from raw: String) -> [Double]? {
        let segment = numericSegment(from: raw)
        guard !segment.isEmpty else { return nil }

        var values: [Double] = []
        values.reserveCapacity(keys.count)

        for key in keys {
            guard let value = extractValue(for: key, in: segment) else {
                return nil
            }
            values.append(value)
        }

        return values
    }

    private func numericSegment(from raw: String) -> String {
        guard let openBrace = raw.firstIndex(of: "{"),
              let closeBrace = raw.lastIndex(of: "}") else {
            return raw
        }

        var segment = String(raw[raw.index(after: openBrace)..<closeBrace])

        if let typeRange = segment.range(of: "type", options: [.caseInsensitive]) {
            segment = String(segment[..<typeRange.lowerBound])
        }

        if let valueRange = segment.range(of: "value", options: [.caseInsensitive]) {
            var remainder = String(segment[valueRange.upperBound...])
            if let equalsRange = remainder.range(of: "=") {
                remainder = String(remainder[equalsRange.upperBound...])
            }
            segment = remainder
        }

        return segment.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func extractValue(for key: String, in segment: String) -> Double? {
        let escapedKey = NSRegularExpression.escapedPattern(for: key)
        let pattern = "(?:^|[\\s,])\(escapedKey)\\s*:\\s*(-?\\d+(?:\\.\\d+)?)"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }

        let searchRange = NSRange(segment.startIndex..., in: segment)
        guard let match = regex.firstMatch(in: segment, options: [], range: searchRange),
              match.numberOfRanges >= 2,
              let valueRange = Range(match.range(at: 1), in: segment) else {
            return nil
        }

        return Double(segment[valueRange])
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

    private func isStructureNode(attributes: [String: String]) -> Bool {
        let keys = attributes.keys.map { $0.lowercased() }
        return !keys.contains("role") && !keys.contains("text")
    }

    private func nodeValue(_ node: AccessibilityNode, configuration: Configuration) -> YAMLValue {
        switch configuration.mode {
        case .all:
            return nodeValueAll(node, configuration: configuration)
        case .llm:
            return nodeValueLLM(node, configuration: configuration)
        }
    }

    private func nodeValueAll(_ node: AccessibilityNode, configuration: Configuration) -> YAMLValue {
        var map: [String: YAMLValue] = [:]

        if !node.attributes.isEmpty {
            var attributes: [String: YAMLValue] = [:]
            for key in node.attributes.keys.sorted() {
                attributes[key] = .string(node.attributes[key] ?? "")
            }
            map["attributes"] = .dictionary(attributes)
        }

        if !node.children.isEmpty {
            let values = node.children.map { nodeValue($0, configuration: configuration) }
            map["children"] = .array(values)
        }

        return .dictionary(map)
    }

    private func nodeValueLLM(_ node: AccessibilityNode, configuration: Configuration) -> YAMLValue {
        var map: [String: YAMLValue] = [:]

        if !node.attributes.isEmpty {
            for key in orderedAttributeKeys(node.attributes) {
                if let value = node.attributes[key] {
                    map[key] = .string(value)
                }
            }
        }

        if !node.children.isEmpty {
            let values = node.children.map { nodeValue($0, configuration: configuration) }
            map["children"] = .array(values)
        }

        return .dictionary(map)
    }

    private func orderedAttributeKeys(_ attributes: [String: String]) -> [String] {
        let priority = ["role", "text", "identifier", "focused", "enabled", "x", "y", "width", "height"]
        var seen: Set<String> = []
        var ordered: [String] = []

        for key in priority where attributes[key] != nil {
            ordered.append(key)
            seen.insert(key)
        }

        let remaining = attributes.keys
            .filter { !seen.contains($0) }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }

        ordered.append(contentsOf: remaining)
        return ordered
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
