import ApplicationServices

/// Describes how the accessibility tree should be captured and later rendered.
/// Provides shared knobs for both the collector and the renderer so variants stay in sync.
struct AccessibilityTreeConfiguration {
    /// Capture/render mode. `.llm` applies aggressive filtering, `.all` keeps raw structure.
    enum Mode {
        case llm(LLMOptions)
        case all
    }

    /// Fine-grained options that control how the LLM-focused variant is trimmed and normalised.
    struct LLMOptions {
        /// Attribute keys used to locate an element's role.
        let roleKeys: [String]
        /// Attribute keys that may contain user-visible text to surface.
        let textKeys: [String]
        /// Attribute keys used to derive a stable identifier.
        let identifierKeys: [String]
        /// Optional attribute key that stores the element's position.
        let positionKey: String?
        /// Optional attribute key that stores the element's size.
        let sizeKey: String?
        /// Attribute keys that reveal enabled/disabled state.
        let enabledKeys: [String]
        /// Attribute keys that reveal focus state.
        let focusedKeys: [String]
        /// When true roles such as `AXGroup` are dropped to reduce noise.
        let dropGroupRoles: Bool
        /// When true the `enabled` attribute is emitted only if the element is disabled.
        let emitEnabledOnlyWhenFalse: Bool
        /// When true the `focused` attribute is emitted only if the element is focused.
        let emitFocusedOnlyWhenTrue: Bool
        /// When true layout information (position/size) is preserved.
        let includeFrame: Bool
        /// Roles that should not be traversed in the LLM variant.
        let prunedRoles: Set<String>
    }

    let mode: Mode
    /// When true only text-bearing nodes (and their ancestors) are kept.
    let includeOnlyTextNodesAndAncestors: Bool
    /// When true attribute-free leaves are removed to reduce noise.
    let pruneAttributeLessLeaves: Bool
    /// When true structural nodes drop their attributes to reduce serialization size.
    let stripAttributesFromStructureNodes: Bool
    /// When false hidden nodes are skipped during capture and never rendered.
    let includeHiddenElements: Bool

    /// Default configuration tuned for LLM consumption: aggressive pruning, hidden filtering on.
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
                prunedRoles: ["AXList"]
            )
        ),
        includeOnlyTextNodesAndAncestors: false,
        pruneAttributeLessLeaves: true,
        stripAttributesFromStructureNodes: true,
        includeHiddenElements: false
    )

    /// Default configuration that preserves as much of the raw tree as possible.
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
