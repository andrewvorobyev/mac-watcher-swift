import Foundation

protocol AccessibilityTreeRenderer {
    func render(node: AccessibilityNode) throws -> Data
}

final class YAMLAccessibilityTreeRenderer: AccessibilityTreeRenderer {
    private let configuration: AccessibilityTreeConfiguration

    init(configuration: AccessibilityTreeConfiguration) {
        self.configuration = configuration
    }

    func render(node: AccessibilityNode) throws -> Data {
        let nodesForRendering: [AccessibilityNode]
        switch configuration.mode {
        case .all:
            nodesForRendering = [node]
        case .llm:
            nodesForRendering = pruneTextlessNodes(from: node)
        }

        let contentValue: YAMLValue
        switch configuration.mode {
        case .all:
            contentValue = nodeValueAll(node)
        case .llm:
            contentValue = .array(nodesForRendering.map { nodeValueLLM($0) })
        }

        let rootValue: YAMLValue = .dictionary([
            "accessibilityTree": contentValue
        ])
        let lines = serialize(rootValue, indentLevel: 0)
        let yaml = lines.joined(separator: "\n") + "\n"
        return Data(yaml.utf8)
    }
    private func pruneTextlessNodes(from node: AccessibilityNode) -> [AccessibilityNode] {
        let prunedChildren = node.children.flatMap { pruneTextlessNodes(from: $0) }
        let textValue = node.attributes["text"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasText = !(textValue?.isEmpty ?? true)

        if hasText {
            let newNode = AccessibilityNode(attributes: node.attributes, children: prunedChildren)
            return [newNode]
        }

        return prunedChildren
    }

    private func nodeValueAll(_ node: AccessibilityNode) -> YAMLValue {
        var map: [String: YAMLValue] = [:]

        if !node.attributes.isEmpty {
            var attributes: [String: YAMLValue] = [:]
            for key in node.attributes.keys.sorted() {
                attributes[key] = .string(node.attributes[key] ?? "")
            }
            map["attributes"] = .dictionary(attributes)
        }

        if !node.children.isEmpty {
            let values = node.children.map { nodeValueAll($0) }
            map["children"] = .array(values)
        }

        return .dictionary(map)
    }

    private func nodeValueLLM(_ node: AccessibilityNode) -> YAMLValue {
        var map: [String: YAMLValue] = [:]

        if !node.attributes.isEmpty {
            for key in orderedAttributeKeys(node.attributes) {
                if let value = node.attributes[key] {
                    map[key] = .string(value)
                }
            }
        }

        if !node.children.isEmpty {
            let values = node.children.map { nodeValueLLM($0) }
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
