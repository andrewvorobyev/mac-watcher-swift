import Foundation
import ApplicationServices

enum AXValueUtilities {
    static func stringify(_ value: Any) -> String {
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

    static func summarizeText(_ text: String) -> String {
        let condensed = condenseWhitespace(text)
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

    static func condenseWhitespace(_ text: String) -> String {
        let condensed = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return condensed.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func parseBoolean(_ value: String) -> Bool? {
        let lowercased = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if ["true", "1", "yes"].contains(lowercased) {
            return true
        }
        if ["false", "0", "no"].contains(lowercased) {
            return false
        }
        return nil
    }

    private static func summarizeScalar(_ string: String) -> String {
        guard string.count > 256 else { return string }
        let index = string.index(string.startIndex, offsetBy: 256)
        let prefix = String(string[string.startIndex..<index])
        let trimmed = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        let remainder = string.count - trimmed.count
        return "\(trimmed)… (+\(remainder) chars)"
    }
}
