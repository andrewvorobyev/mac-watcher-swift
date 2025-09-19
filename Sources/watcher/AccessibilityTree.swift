import Foundation
import ApplicationServices

struct AccessibilityNode {
    let attributes: [String: String]
    let children: [AccessibilityNode]
}

struct AccessibilityTreeConfiguration {
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
        let includeFrame: Bool
        let prunedRoles: Set<String>
    }

    let mode: Mode
    let includeOnlyTextNodesAndAncestors: Bool
    let pruneAttributeLessLeaves: Bool
    let stripAttributesFromStructureNodes: Bool
    let includeHiddenElements: Bool

    static let llm = AccessibilityTreeConfiguration(
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
                emitFocusedOnlyWhenTrue: true,
                includeFrame: false,
                prunedRoles: ["AXList", "AXWebArea"]
            )
        ),
        includeOnlyTextNodesAndAncestors: false,
        pruneAttributeLessLeaves: true,
        stripAttributesFromStructureNodes: true,
        includeHiddenElements: false
    )

    static let all = AccessibilityTreeConfiguration(
        mode: .all,
        includeOnlyTextNodesAndAncestors: false,
        pruneAttributeLessLeaves: false,
        stripAttributesFromStructureNodes: false,
        includeHiddenElements: false
    )

    var attributeWhitelist: Set<String>? {
        switch mode {
        case .all:
            return nil
        case .llm(let options):
            var names = Set<String>()
            names.formUnion(options.roleKeys)
            names.formUnion(options.textKeys)
            names.formUnion(options.identifierKeys)
            names.formUnion(options.enabledKeys)
            names.formUnion(options.focusedKeys)
            names.insert(kAXHiddenAttribute as String)
            if let positionKey = options.positionKey {
                names.insert(positionKey)
            }
            if let sizeKey = options.sizeKey {
                names.insert(sizeKey)
            }
            names.insert(kAXRoleAttribute as String)
            names.insert(kAXSubroleAttribute as String)
            return names
        }
    }
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
    private let configuration: AccessibilityTreeConfiguration
    private let childrenAttributeName = kAXChildrenAttribute as String
    private let hiddenAttributeName = kAXHiddenAttribute as String
    private let visibleChildrenAttributeName = kAXVisibleChildrenAttribute as String
    private let childrenAttributeNameLower: String
    private let hiddenAttributeNameLower: String
    private let visibleChildrenAttributeNameLower: String

    init(configuration: AccessibilityTreeConfiguration) {
        self.configuration = configuration
        self.childrenAttributeNameLower = (kAXChildrenAttribute as String).lowercased()
        self.hiddenAttributeNameLower = (kAXHiddenAttribute as String).lowercased()
        self.visibleChildrenAttributeNameLower = (kAXVisibleChildrenAttribute as String).lowercased()
    }

    convenience init() {
        self.init(configuration: .all)
    }

    func collectTree(for pid: pid_t) throws -> AccessibilityNode {
        guard AXIsProcessTrusted() else {
            throw AccessibilityCollectorError.accessibilityPermissionMissing
        }

        let appElement = AXUIElementCreateApplication(pid)
        var visited: Set<AXElementID> = []
        guard let node = buildNode(from: appElement, visited: &visited) else {
            return AccessibilityNode(attributes: [:], children: [])
        }
        return node
    }

    private func buildNode(from element: AXUIElement, visited: inout Set<AXElementID>) -> AccessibilityNode? {
        let identifier = AXElementID(element: element)
        if visited.contains(identifier) {
            return AccessibilityNode(attributes: ["cycle": "true"], children: [])
        }
        visited.insert(identifier)

        let attributeNamesResult = copyAttributeNames(from: element)
        switch attributeNamesResult {
        case .failure(let error):
            return AccessibilityNode(attributes: ["error.attributeNames": error.description], children: [])
        case .success(let attributeNames):
            let namesToFetch = filteredAttributeNames(from: attributeNames)
            let (rawAttributes, attributeErrors) = copyAttributeValues(element: element, names: namesToFetch)

            if !configuration.includeHiddenElements && isHidden(attributes: rawAttributes) {
                visited.remove(identifier)
                return nil
            }

            let roleForTraversal = rawAttributes[kAXRoleAttribute as String]

            var children: [AccessibilityNode] = []
            if shouldTraverseChildren(role: roleForTraversal), attributeNames.contains(where: { $0.caseInsensitiveCompare(childrenAttributeName) == .orderedSame }) {
                switch copyChildren(from: element, visited: &visited) {
                case .success(let nodes):
                    children = nodes
                case .failure(let error):
                    children = []
                    var attributes: [String: String] = ["error.children": error.description]
                    attributes.merge(processAttributes(rawAttributes)) { current, _ in current }
                    if case .all = configuration.mode {
                        for (name, attrError) in attributeErrors {
                            attributes["error.attribute.\(name)"] = attrError.description
                        }
                    }
                    return finalizeNode(attributes: attributes, children: [])
                }
            }

            var attributes = processAttributes(rawAttributes)
            if case .all = configuration.mode {
                for (name, attrError) in attributeErrors {
                    attributes["error.attribute.\(name)"] = attrError.description
                }
            }

            return finalizeNode(attributes: attributes, children: children)
        }
    }

    private func copyAttributeNames(from element: AXUIElement) -> Result<[String], AccessibilityCollectorError> {
        var attributeNamesCF: CFArray?
        let namesError = AXUIElementCopyAttributeNames(element, &attributeNamesCF)
        switch namesError {
        case .success:
            if let names = attributeNamesCF as? [String] {
                return .success(names)
            }
            return .success([])
        case .attributeUnsupported:
            return .success([])
        default:
            return .failure(.axError(namesError))
        }
    }

    private func filteredAttributeNames(from available: [String]) -> [String] {
        let whitelist = configuration.attributeWhitelist
        var seen: Set<String> = []
        var filtered: [String] = []

        for name in available {
            let lower = name.lowercased()
            if lower == childrenAttributeNameLower {
                continue
            }
            if lower == visibleChildrenAttributeNameLower {
                continue
            }
            if let whitelist,
               !whitelist.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
                continue
            }
            if seen.insert(lower).inserted {
                filtered.append(name)
            }
        }

        if let whitelist {
            for name in whitelist {
                let lower = name.lowercased()
                if lower == childrenAttributeNameLower {
                    continue
                }
                if lower == visibleChildrenAttributeNameLower {
                    continue
                }
                if seen.insert(lower).inserted {
                    filtered.append(name)
                }
            }
        }

        if !configuration.includeHiddenElements && seen.insert(hiddenAttributeNameLower).inserted {
            filtered.append(hiddenAttributeName)
        }

        return filtered
    }

    private func shouldTraverseChildren(role: String?) -> Bool {
        guard case .llm(let options) = configuration.mode, let role else {
            return true
        }

        for prunedRole in options.prunedRoles {
            if prunedRole.caseInsensitiveCompare(role) == .orderedSame {
                return false
            }
        }
        return true
    }

    private func copyChildren(from element: AXUIElement, visited: inout Set<AXElementID>) -> Result<[AccessibilityNode], AccessibilityCollectorError> {
        let elementsResult: Result<[AXUIElement], AccessibilityCollectorError>
        if !configuration.includeHiddenElements {
            if let visible = copyChildrenAttribute(element: element, attribute: kAXVisibleChildrenAttribute as CFString) {
                switch visible {
                case .success:
                    elementsResult = visible
                case .failure:
                    elementsResult = copyChildrenAttribute(element: element, attribute: kAXChildrenAttribute as CFString) ?? visible
                }
            } else {
                elementsResult = copyChildrenAttribute(element: element, attribute: kAXChildrenAttribute as CFString) ?? .success([])
            }
        } else {
            elementsResult = copyChildrenAttribute(element: element, attribute: kAXChildrenAttribute as CFString) ?? .success([])
        }

        switch elementsResult {
        case .failure(let error):
            return .failure(error)
        case .success(let elements):
            return buildChildren(from: elements, visited: &visited)
        }
    }

    private func copyChildrenAttribute(element: AXUIElement, attribute: CFString) -> Result<[AXUIElement], AccessibilityCollectorError>? {
        var childrenCF: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute, &childrenCF)
        if error == .attributeUnsupported {
            return nil
        }
        if error != .success {
            return .failure(.axError(error))
        }

        guard let array = childrenCF as? [AXUIElement] else {
            return .success([])
        }

        return .success(array)
    }

    private func buildChildren(from elements: [AXUIElement], visited: inout Set<AXElementID>) -> Result<[AccessibilityNode], AccessibilityCollectorError> {
        var result: [AccessibilityNode] = []
        result.reserveCapacity(elements.count)

        for child in elements {
            if let node = buildNode(from: child, visited: &visited) {
                result.append(node)
            }
        }

        return .success(result)
    }

    private func copyAttributeValues(element: AXUIElement, names: [String]) -> (attributes: [String: String], errors: [String: AccessibilityCollectorError]) {
        guard !names.isEmpty else { return ([:], [:]) }

        let cfNames = names.map { $0 as CFString } as CFArray
        var valuesCF: CFArray?
        let error = AXUIElementCopyMultipleAttributeValues(element, cfNames, [], &valuesCF)

        var attributes: [String: String] = [:]
        var errors: [String: AccessibilityCollectorError] = [:]

        if error == .success, let values = valuesCF as? [Any] {
            for (index, rawValue) in values.enumerated() {
                guard index < names.count else { continue }
                let name = names[index]
                if rawValue is NSNull {
                    continue
                }
                let cfObject = rawValue as AnyObject
                if CFGetTypeID(cfObject) == AXValueGetTypeID() {
                    let axValue = unsafeDowncast(cfObject, to: AXValue.self)
                    let valueType = AXValueGetType(axValue)
                    if valueType.rawValue == kAXValueAXErrorType {
                        var axError = AXError.success
                        if AXValueGetValue(axValue, valueType, &axError) {
                            errors[name] = .axError(axError)
                        } else {
                            errors[name] = .axError(.cannotComplete)
                        }
                        continue
                    }
                }
                attributes[name] = stringify(rawValue)
            }
            return (attributes, errors)
        }

        for name in names {
            switch copySingleAttributeValue(element: element, attribute: name) {
            case .success(let value):
                if let value {
                    attributes[name] = value
                }
            case .failure(let attrError):
                errors[name] = attrError
            }
        }

        return (attributes, errors)
    }

    private func copySingleAttributeValue(element: AXUIElement, attribute: String) -> Result<String?, AccessibilityCollectorError> {
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

        guard let raw = value else {
            return .success(nil)
        }
        return .success(stringify(raw))
    }

    private func processAttributes(_ attributes: [String: String]) -> [String: String] {
        switch configuration.mode {
        case .all:
            return attributes
        case .llm(let options):
            return filterAttributes(attributes, options: options)
        }
    }

    private func finalizeNode(attributes: [String: String], children: [AccessibilityNode]) -> AccessibilityNode? {
        var attributes = attributes
        let children = children

        attributes.removeValue(forKey: "identifier")
        attributes.removeValue(forKey: "error.children")

        if configuration.stripAttributesFromStructureNodes && isStructureNode(attributes: attributes) {
            attributes.removeAll()
        }

        if configuration.includeOnlyTextNodesAndAncestors {
            let hasText = nodeContainsText(attributes: attributes)
            if !hasText && children.isEmpty {
                return nil
            }
        }

        if configuration.pruneAttributeLessLeaves && attributes.isEmpty && children.isEmpty {
            return nil
        }

        return AccessibilityNode(attributes: attributes, children: children)
    }

    private func isHidden(attributes: [String: String]) -> Bool {
        for (key, value) in attributes {
            if key.compare(kAXHiddenAttribute as String, options: [.caseInsensitive]) == .orderedSame {
                if let hidden = parseBoolean(value) {
                    return hidden
                }
            }
        }
        return false
    }

    private func stringify(_ value: Any) -> String {
        if let string = value as? String {
            return summarizeScalar(string)
        }
        if let attributed = value as? NSAttributedString {
            return summarizeScalar(attributed.string)
        }
        if let number = value as? NSNumber {
            if CFGetTypeID(number as CFTypeRef) == CFBooleanGetTypeID() {
                return number.boolValue ? "true" : "false"
            }
            return number.stringValue
        }
        if let array = value as? [Any] {
            if array.isEmpty {
                return "[]"
            }
            if array.count > 24 {
                return "Array(count: \(array.count))"
            }
            let elements = array.prefix(24).map { stringify($0) }
            let suffix = array.count > 24 ? ", …" : ""
            return "[" + elements.joined(separator: ", ") + suffix + "]"
        }
        if let dictionary = value as? [AnyHashable: Any] {
            if dictionary.isEmpty {
                return "{}"
            }
            if dictionary.count > 24 {
                return "Dictionary(count: \(dictionary.count))"
            }
            let pairs = dictionary
                .map { key, value -> String in
                    let keyString = String(describing: key)
                    let valueString = stringify(value)
                    return "\(keyString): \(valueString)"
                }
                .sorted()
            return "{" + pairs.joined(separator: ", ") + "}"
        }
        let cfObject = value as AnyObject
        if CFGetTypeID(cfObject) == AXUIElementGetTypeID() {
            return "AXUIElement"
        }
        return summarizeScalar(String(describing: value))
    }

    private func summarizeScalar(_ string: String) -> String {
        guard string.count > 256 else { return string }
        let index = string.index(string.startIndex, offsetBy: 256)
        let prefix = String(string[string.startIndex..<index])
        let trimmed = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        let remainder = string.count - trimmed.count
        return "\(trimmed)… (+\(remainder) chars)"
    }

    private func filterAttributes(_ attributes: [String: String], options: AccessibilityTreeConfiguration.LLMOptions) -> [String: String] {
        var result: [String: String] = [:]

        if let role = firstMatch(in: attributes, keys: options.roleKeys), !shouldDrop(role: role, dropGroupRoles: options.dropGroupRoles) {
            result["role"] = condenseWhitespace(in: role)
        }

        if let identifier = firstMatch(in: attributes, keys: options.identifierKeys) {
            result["identifier"] = condenseWhitespace(in: identifier)
        }

        if let text = aggregateText(from: attributes, keys: options.textKeys) {
            result["text"] = summarizeText(text)
        }

        if options.includeFrame {
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
