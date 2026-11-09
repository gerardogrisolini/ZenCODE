import Foundation
import ToolCore
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
    // `baseDescriptors` already includes the core Search tools.
    let descriptor = DirectToolCatalog.baseDescriptors.first { $0.name == name }
    let ownedPresentation: ToolPresentationDefinition?
    if let presentation {
        ownedPresentation = presentation
    } else if let descriptor {
        ownedPresentation = descriptor.presentation
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
