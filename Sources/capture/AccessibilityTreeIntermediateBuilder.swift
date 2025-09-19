import Foundation

enum AccessibilityTreeValue {
    case string(String)
    case object([String: AccessibilityTreeValue])
    case array([AccessibilityTreeValue])

    func toJSONObject() -> Any {
        switch self {
        case .string(let string):
            return string
        case .object(let dictionary):
            var result: [String: Any] = [:]
            for (key, value) in dictionary {
                result[key] = value.toJSONObject()
            }
            return result
        case .array(let array):
            return array.map { $0.toJSONObject() }
        }
    }
}

enum AccessibilityTreeIntermediateBuilder {
    static func buildRoot(node: AccessibilityNode, configuration: AccessibilityTreeConfiguration) -> AccessibilityTreeValue {
        let content: AccessibilityTreeValue
        switch configuration.mode {
        case .all:
            content = nodeValueAll(node)
        case .llm:
            let nodes = pruneTextlessNodes(from: node)
            content = .array(nodes.map { nodeValueLLM($0) })
        }
        return .object(["accessibilityTree": content])
    }

    private static func nodeValueAll(_ node: AccessibilityNode) -> AccessibilityTreeValue {
        var map: [String: AccessibilityTreeValue] = [:]

        if !node.attributes.isEmpty {
            var attributes: [String: AccessibilityTreeValue] = [:]
            for key in node.attributes.keys.sorted() {
                attributes[key] = .string(node.attributes[key] ?? "")
            }
            map["attributes"] = .object(attributes)
        }

        if !node.children.isEmpty {
            let values = node.children.map { nodeValueAll($0) }
            map["children"] = .array(values)
        }

        return .object(map)
    }

    private static func nodeValueLLM(_ node: AccessibilityNode) -> AccessibilityTreeValue {
        var map: [String: AccessibilityTreeValue] = [:]

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

        return .object(map)
    }

    private static func pruneTextlessNodes(from node: AccessibilityNode) -> [AccessibilityNode] {
        let prunedChildren = node.children.flatMap { pruneTextlessNodes(from: $0) }
        let textValue = node.attributes["text"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasText = !(textValue?.isEmpty ?? true)

        if hasText {
            let newNode = AccessibilityNode(attributes: node.attributes, children: prunedChildren)
            return [newNode]
        }

        return prunedChildren
    }

    private static func orderedAttributeKeys(_ attributes: [String: String]) -> [String] {
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
}
