import Foundation

final class JSONAccessibilityTreeRenderer: AccessibilityTreeRenderer {
    enum Style {
        case compact
        case pretty
    }

    private let configuration: AccessibilityTreeConfiguration
    private let style: Style

    init(configuration: AccessibilityTreeConfiguration, style: Style) {
        self.configuration = configuration
        self.style = style
    }

    func render(node: AccessibilityNode) throws -> Data {
        let rootValue = AccessibilityTreeIntermediateBuilder.buildRoot(node: node, configuration: configuration)
        guard let jsonObject = rootValue.toJSONObject() as? [String: Any] else {
            throw NSError(domain: "JSONAccessibilityTreeRenderer", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unexpected root JSON structure"])
        }

        let options: JSONSerialization.WritingOptions = (style == .pretty) ? [.prettyPrinted] : []
        return try JSONSerialization.data(withJSONObject: jsonObject, options: options)
    }
}
