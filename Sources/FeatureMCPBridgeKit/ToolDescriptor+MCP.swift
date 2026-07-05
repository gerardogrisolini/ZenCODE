import ToolCore

extension ToolDescriptor {
    public init(remoteTool: MCPRemoteTool) {
        self.init(
            name: remoteTool.name,
            title: remoteTool.title,
            description: remoteTool.description ?? "No description provided by the tool backend.",
            inputSchema: remoteTool.inputSchema?.prettyPrinted() ?? "{}",
            outputSchema: remoteTool.outputSchema?.prettyPrinted()
        )
    }
}
