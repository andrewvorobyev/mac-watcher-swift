import ApplicationServices

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
                prunedRoles: ["AXList"]
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
