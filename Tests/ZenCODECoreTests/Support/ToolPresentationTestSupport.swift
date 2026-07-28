import Foundation
@testable import ZenCODECore

/// Builds a tool call through the same descriptor-owned presentation contract
/// used by live remote rounds. Tests that intentionally exercise legacy or
/// third-party calls without metadata should keep using `DirectAgentToolCall`
/// directly.
func presentedToolCall(
    id: String,
    name: String,
    argumentsObject: [String: Any],
    argumentsJSON: String,
    descriptorTitle: String? = nil,
    presentation: ToolPresentationDefinition? = nil
) -> DirectAgentToolCall {
    let descriptor = (
        DirectToolCatalog.baseDescriptors
            + DirectToolCatalog.localSearchDescriptors
    ).first { $0.name == name }
    let ownedPresentation: ToolPresentationDefinition?
    if let presentation {
        ownedPresentation = presentation
    } else if let descriptor {
        ownedPresentation = descriptor.presentation
    } else if name.hasPrefix("xcode.") {
        ownedPresentation = XcodeToolIntegration.presentation(
            for: ToolDescriptor(
                name: name,
                title: descriptorTitle,
                description: "Test descriptor",
                inputSchema: "{}"
            )
        )
    } else {
        ownedPresentation = nil
    }

    return DirectAgentToolCall(
        id: id,
        name: name,
        argumentsObject: argumentsObject,
        argumentsJSON: argumentsJSON,
        descriptorTitle: descriptorTitle ?? descriptor?.title,
        presentation: ownedPresentation
    )
}
