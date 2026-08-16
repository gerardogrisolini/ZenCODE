//
//  SwiftFeatureManagementToolDescriptors.swift
//  ZenCODE
//

import Foundation
import ToolCore

extension SwiftFeatureRuntime {
    static let managementToolAliases = ["feature.update": "feature.edit"]

    private static let canonicalManagementToolDescriptors: [DirectToolDescriptor] = [
        DirectToolDescriptor(
            name: "feature.list",
            description: "Lists Swift feature bundles known to the kernel, including bundled and generated features plus enabled status.",
            inputSchema: #"{"type":"object","properties":{"includeTools":{"type":"boolean"},"include_tools":{"type":"boolean"},"includeDisabled":{"type":"boolean"},"include_disabled":{"type":"boolean"},"discoverRuntimeTools":{"type":"boolean"},"discover_runtime_tools":{"type":"boolean"}}}"#,
            presentation: .standard(title: "Features", action: "List", kind: .read, targetKeyPaths: ["includeTools", "include_tools", "includeDisabled", "include_disabled", "discoverRuntimeTools", "discover_runtime_tools"])
        ),
        DirectToolDescriptor(
            name: "feature.enable",
            description: "Enables a Swift feature bundle by id and reloads the feature runtime.",
            inputSchema: #"{"type":"object","properties":{"id":{"type":"string"},"featureID":{"type":"string"},"feature_id":{"type":"string"},"name":{"type":"string"}},"required":["id"]}"#,
            presentation: .standard(title: "Feature", action: "Enable", kind: .manage, targetKeyPaths: ["id", "featureID", "feature_id", "name"])
        ),
        DirectToolDescriptor(
            name: "feature.disable",
            description: "Disables a Swift feature bundle by id and reloads the feature runtime.",
            inputSchema: #"{"type":"object","properties":{"id":{"type":"string"},"featureID":{"type":"string"},"feature_id":{"type":"string"},"name":{"type":"string"}},"required":["id"]}"#,
            presentation: .standard(title: "Feature", action: "Disable", kind: .manage, targetKeyPaths: ["id", "featureID", "feature_id", "name"])
        ),
        DirectToolDescriptor(
            name: "feature.delete",
            description: "Deletes a generated Swift feature package by id and reloads the feature runtime. Bundled features cannot be deleted directly.",
            inputSchema: #"{"type":"object","properties":{"id":{"type":"string"},"featureID":{"type":"string"},"feature_id":{"type":"string"},"name":{"type":"string"}},"required":["id"]}"#,
            presentation: .standard(title: "Feature", action: "Delete", kind: .delete, targetKeyPaths: ["id", "featureID", "feature_id", "name"])
        ),
        DirectToolDescriptor(
            name: "feature.edit",
            description: "Prepares an editable Swift feature package context. Generated features are opened directly; bundled features are copied into the generated feature root first.",
            inputSchema: #"{"type":"object","properties":{"id":{"type":"string"},"featureID":{"type":"string"},"feature_id":{"type":"string"},"name":{"type":"string"},"overwrite":{"type":"boolean"},"enabled":{"type":"boolean"},"sourcePath":{"type":"string"},"source_path":{"type":"string"},"zenPackagePath":{"type":"string"},"zen_package_path":{"type":"string"},"dependencyPath":{"type":"string"},"dependency_path":{"type":"string"}},"required":["id"]}"#,
            presentation: .standard(title: "Feature", action: "Edit", kind: .edit, targetKeyPaths: ["id", "featureID", "feature_id", "name"])
        ),
        DirectToolDescriptor(
            name: "feature.reload",
            description: "Reloads Swift feature bundles from bundled executables and generated feature manifests.",
            inputSchema: #"{"type":"object","properties":{"includeTools":{"type":"boolean"},"include_tools":{"type":"boolean"},"includeDisabled":{"type":"boolean"},"include_disabled":{"type":"boolean"},"discoverRuntimeTools":{"type":"boolean"},"discover_runtime_tools":{"type":"boolean"}}}"#,
            presentation: .standard(title: "Features", action: "Reload", kind: .execute, targetKeyPaths: ["includeTools", "include_tools", "discoverRuntimeTools", "discover_runtime_tools"])
        ),
        DirectToolDescriptor(
            name: "feature.validate",
            description: "Validates a generated Swift feature manifest, tool names, executable state, and SwiftPM package tools version.",
            inputSchema: #"{"type":"object","properties":{"id":{"type":"string"},"featureID":{"type":"string"},"feature_id":{"type":"string"},"name":{"type":"string"},"path":{"type":"string"},"manifestPath":{"type":"string"},"manifest_path":{"type":"string"}}}"#,
            presentation: .standard(title: "Feature", action: "Validate", kind: .inspect, targetKeyPaths: ["id", "featureID", "feature_id", "name", "path"])
        ),
        DirectToolDescriptor(
            name: "feature.build",
            description: "Builds a generated Swift feature package with SwiftPM and reloads the feature runtime when the executable is produced.",
            inputSchema: #"{"type":"object","properties":{"id":{"type":"string"},"featureID":{"type":"string"},"feature_id":{"type":"string"},"name":{"type":"string"},"path":{"type":"string"},"manifestPath":{"type":"string"},"manifest_path":{"type":"string"},"timeoutSeconds":{"type":"number"},"timeout":{"type":"number"}}}"#,
            presentation: .standard(title: "Feature", action: "Build", kind: .execute, targetKeyPaths: ["id", "featureID", "feature_id", "name", "path"])
        ),
        DirectToolDescriptor(
            name: "feature.scaffold",
            description: "Creates a Swift 6.3 SwiftPM feature package scaffold under the generated features directory. Use template=mcp-bridge for MCP service bridges. Pass build=true and/or enable=true to validate, build, and enable the package in one call. MCP endpoint URLs containing credentials are rejected, as are non-empty environment/env values; stdio bridges inherit the environment used to launch ZenCODE.",
            inputSchema: #"{"type":"object","properties":{"id":{"type":"string"},"template":{"type":"string","enum":["basic","mcp-bridge"]},"kind":{"type":"string"},"displayName":{"type":"string"},"display_name":{"type":"string"},"serviceName":{"type":"string"},"service_name":{"type":"string"},"description":{"type":"string"},"toolName":{"type":"string"},"tool_name":{"type":"string"},"toolPrefix":{"type":"string"},"tool_prefix":{"type":"string"},"prefix":{"type":"string"},"endpointURL":{"type":"string"},"endpoint_url":{"type":"string"},"url":{"type":"string"},"executablePath":{"type":"string"},"executable_path":{"type":"string"},"command":{"type":"string"},"arguments":{"type":["array","string"],"items":{"type":"string"}},"args":{"type":["array","string"],"items":{"type":"string"}},"environment":{"type":"object","additionalProperties":{"type":"string"}},"env":{"type":"object","additionalProperties":{"type":"string"}},"dependencyPath":{"type":"string"},"dependency_path":{"type":"string"},"path":{"type":"string"},"directory":{"type":"string"},"directoryPath":{"type":"string"},"directory_path":{"type":"string"},"enabled":{"type":"boolean"},"overwrite":{"type":"boolean"},"build":{"type":"boolean"},"enable":{"type":"boolean"},"timeoutSeconds":{"type":"number"},"timeout":{"type":"number"}},"required":["id"]}"#,
            presentation: .standard(title: "Feature", action: "Scaffold", kind: .create, targetKeyPaths: ["id", "displayName", "display_name", "toolName", "tool_name"] )
        ),
        DirectToolDescriptor(
            name: "feature.install",
            description: "Installs a generated Swift feature package into the ZenCODE feature root, optionally building and enabling it.",
            inputSchema: #"{"type":"object","properties":{"id":{"type":"string"},"featureID":{"type":"string"},"feature_id":{"type":"string"},"name":{"type":"string"},"path":{"type":"string"},"directory":{"type":"string"},"directoryPath":{"type":"string"},"directory_path":{"type":"string"},"manifestPath":{"type":"string"},"manifest_path":{"type":"string"},"overwrite":{"type":"boolean"},"build":{"type":"boolean"},"enable":{"type":"boolean"},"timeoutSeconds":{"type":"number"},"timeout":{"type":"number"}}}"#,
            presentation: .standard(title: "Feature", action: "Install", kind: .create, targetKeyPaths: ["id", "featureID", "feature_id", "name", "path"])
        )
    ]

    static let managementToolDescriptors: [DirectToolDescriptor] =
        canonicalManagementToolDescriptors + managementToolAliases.compactMap { alias, canonical in
            guard let descriptor = canonicalManagementToolDescriptors.first(where: { $0.name == canonical }) else {
                return nil
            }
            return DirectToolDescriptor(
                name: alias,
                description: descriptor.description,
                inputSchema: descriptor.inputSchema,
                title: descriptor.title,
                outputSchema: descriptor.outputSchema,
                presentation: descriptor.presentation
            )
        }

}
