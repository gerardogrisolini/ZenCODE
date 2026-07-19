//
//  PortableToolRuntimeCompatibility.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 03/06/26.
//

import FeatureMCPBridgeKit
import ToolCore
import XcodeToolsFeature

public typealias JSONValue = ToolCore.JSONValue
public typealias ToolDescriptor = ToolCore.ToolDescriptor
public typealias ToolProviderSection = ToolCore.ToolProviderSection
public typealias ToolRequest = ToolCore.ToolRequest
public typealias ToolRequestPayload = ToolCore.ToolRequestPayload
public typealias ToolExecutionOutput = ToolCore.ToolExecutionOutput
public typealias XcodeWorkspaceContext = XcodeToolsFeature.XcodeWorkspaceContext
public typealias XcodeToolRequestCompatibility = XcodeToolsFeature.XcodeToolRequestCompatibility
public typealias SubAgentToolRequestCompatibility = ToolCore.SubAgentToolRequestCompatibility
public typealias DeveloperToolEnvironment = ToolCore.DeveloperToolEnvironment

public typealias MCPBrowserOAuthConfiguration = FeatureMCPBridgeKit.MCPBrowserOAuthConfiguration
public typealias MCPClient = FeatureMCPBridgeKit.MCPClient
public typealias MCPClientError = FeatureMCPBridgeKit.MCPClientError
public typealias MCPErrorResponse = FeatureMCPBridgeKit.MCPErrorResponse
public typealias MCPHTTPAuthentication = FeatureMCPBridgeKit.MCPHTTPAuthentication
#if os(macOS)
public typealias MCPHTTPTransportClient = FeatureMCPBridgeKit.MCPHTTPTransportClient
#endif
public typealias MCPIncomingMessage = FeatureMCPBridgeKit.MCPIncomingMessage
public typealias MCPListToolsResult = FeatureMCPBridgeKit.MCPListToolsResult
public typealias MCPMessageID = FeatureMCPBridgeKit.MCPMessageID
public typealias MCPRemoteTool = FeatureMCPBridgeKit.MCPRemoteTool
public typealias MCPServerConfiguration = FeatureMCPBridgeKit.MCPServerConfiguration
public typealias MCPToolResultRenderer = FeatureMCPBridgeKit.MCPToolResultRenderer
public typealias MCPTransportCodec = FeatureMCPBridgeKit.MCPTransportCodec
public typealias RemoteMCPToolExecutor = FeatureMCPBridgeKit.RemoteMCPToolExecutor
public typealias XcodeToolExecutor = XcodeToolsFeature.XcodeToolExecutor
public typealias XcodeToolIntegration = XcodeToolsFeature.XcodeToolIntegration
