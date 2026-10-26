//
//  DS4ToolsPrompt.swift
//  ZenCODE
//
//  The tools section of the system prompt in each model's native tool syntax.
//  Its structure follows ds4-agent (ds4_agent.c agent_tools_prompt_intro,
//  agent_build_dsml_tools_prompt, agent_build_glm_tools_prompt,
//  agent_build_qwen_tools_prompt and agent_dsml41_tools_prompt) with ZenCODE's
//  tools in place of ds4-agent's built-in schemas. ds4-agent's persona sentence,
//  its tool-specific contracts (read/more/bash/edit/web) and its rules about
//  those tools are intentionally omitted.
//

import Foundation

enum DS4ToolsPrompt {
    /// The tools section for `descriptors`, or an empty string when there are
    /// no tools.
    ///
    /// Tools are listed sorted by name (first descriptor wins on duplicates)
    /// and schemas are minified in their original key order, so the same tool
    /// set always yields the same bytes and the cached prompt prefix can be
    /// reused. An invalid `inputSchema` is replaced by an empty object schema.
    ///
    /// DSML prompts contain the literal `｜DSML｜` markers and `<think>` tags:
    /// tokenize them as rendered chat text (`ds4_tokenize_rendered_chat`) so the
    /// markers become the model's control tokens, as ds4-agent does.
    ///
    /// - Parameter hasVision: currently has no effect. ds4-agent adds its
    ///   `view_image` tool schema for vision models, but ZenCODE has no such
    ///   tool; the flag is kept for when one exists.
    static func toolsPrompt(descriptors: [DirectToolDescriptor], syntax: DS4ToolSyntax, hasVision: Bool) -> String {
        _ = hasVision
        let schemas = functionSchemas(descriptors)
        guard !schemas.isEmpty else {
            return ""
        }
        switch syntax {
        case .dsml, .dsml41:
            return dsmlPrompt(schemas: schemas, syntax: syntax)
        case .glm:
            return glmPrompt(schemas: schemas)
        case .qwen:
            return qwenPrompt(schemas: schemas)
        }
    }

    /// One `{"name":…,"description":…,"parameters":…}` line per tool, in a
    /// stable order.
    static func functionSchemas(_ descriptors: [DirectToolDescriptor]) -> [String] {
        var seen = Set<String>()
        let unique = descriptors.filter { seen.insert($0.name).inserted }
        return unique
            .sorted { $0.name < $1.name }
            .map { descriptor in
                let parameters = DS4JSONText.minifiedObject(descriptor.inputSchema)
                    ?? #"{"type":"object","properties":{}}"#
                return #"{"name":"# + DS4JSONText.quoted(descriptor.name)
                    + #","description":"# + DS4JSONText.quoted(descriptor.description)
                    + #","parameters":"# + parameters + "}"
            }
    }

    // MARK: - DSML (agent_tools_prompt_intro + schemas + rules)

    private static func dsmlPrompt(schemas: [String], syntax: DS4ToolSyntax) -> String {
        let invoke = syntax.dsmlOpenTag(.invoke)
        let parameter = syntax.dsmlOpenTag(.parameter)
        let parameterClose = syntax.parameterCloseMarker
        let escapedClose = "&lt;" + String(parameterClose.dropFirst())
        let doublyEscapedClose = "&amp;" + String(escapedClose.dropFirst())
        let wrapped = schemas.map { #"{"type":"function","function":"# + $0 + "}" }
        let lines: [String] = [
            "## Tools\n\n",
            "You have access to native DSML tools. Invoke tools by writing exactly this shape:\n\n",
            "\(syntax.dsmlOpenTag(.toolCalls))>\n",
            "\(invoke) name=\"$TOOL_NAME\">\n",
            "\(parameter) name=\"$PARAMETER_NAME\" string=\"true|false\">$PARAMETER_VALUE\(parameterClose)\n",
            "\(syntax.dsmlCloseTag(.invoke))\n",
            "\(syntax.dsmlCloseTag(.toolCalls))\n\n",
            "Tool calls are not allowed inside <think></think>; finish thinking before emitting DSML.\n\n",
            "String parameters use raw text and string=\"true\". ",
            "Numbers, booleans, arrays, and objects use JSON text and string=\"false\".\n\n",
            "Inside string values only, escape a literal closing parameter tag as \(escapedClose). ",
            "To write that escaped spelling literally, use \(doublyEscapedClose). Other HTML entities are unchanged.\n\n",
            "### Available Tool Schemas\n\n",
            wrapped.joined(separator: "\n\n"),
            "\n",
            "\n# Rules\n\n",
            "- Always use strict syntax for DSML tool stanzas.\n",
        ]
        return lines.joined()
    }

    // MARK: - GLM (agent_build_glm_tools_prompt)

    private static func glmPrompt(schemas: [String]) -> String {
        let lines: [String] = [
            "# Tools\n\n",
            "You may call one or more functions to assist with the user query.\n\n",
            "You are provided with function signatures within <tools></tools> XML tags:\n",
            "<tools>\n",
            schemas.map { $0 + "\n" }.joined(),
            "</tools>\n\n",
            "Inside argument values only, escape a literal </arg_value> as &lt;/arg_value>. ",
            "To write that escaped spelling literally, use &amp;lt;/arg_value>. Other HTML entities are unchanged.\n\n",
            "For a function call, output the function name and arguments within exactly this XML format:\n",
            "<tool_call>{function-name}<arg_key>{arg-key-1}</arg_key><arg_value>{arg-value-1}</arg_value>",
            "<arg_key>{arg-key-2}</arg_key><arg_value>{arg-value-2}</arg_value>...</tool_call>\n\n",
            "Tool calls are not allowed inside <think></think>; finish thinking before emitting <tool_call>.\n\n",
            "# Rules\n\n",
            "- Use strict native GLM tool-call syntax with <tool_call>, <arg_key>, and <arg_value> tags.\n",
        ]
        return lines.joined()
    }

    // MARK: - Qwen (agent_build_qwen_tools_prompt)

    private static func qwenPrompt(schemas: [String]) -> String {
        let lines: [String] = [
            "# Tools\n\n",
            "You have access to the following functions:\n\n",
            "<tools>",
            schemas.map { "\n{\"type\": \"function\", \"function\": " + $0 + "}" }.joined(),
            "\n</tools>\n\n",
            "Inside string values only, escape a literal </parameter> as &lt;/parameter>. ",
            "To write that escaped spelling literally, use &amp;lt;/parameter>. Other HTML entities are unchanged.\n\n",
            "If you choose to call a function ONLY reply in the following format with NO suffix:\n\n",
            "<tool_call>\n<function=example_function_name>\n<parameter=example_parameter_1>\nvalue_1\n</parameter>\n",
            "<parameter=example_parameter_2>\nThis is the value for the second parameter\nthat can span\nmultiple lines\n",
            "</parameter>\n</function>\n</tool_call>\n\n<IMPORTANT>\nReminder:\n",
            "- Function calls MUST follow the specified format: an inner <function=...></function> block must be nested ",
            "within <tool_call></tool_call> XML tags\n",
            "- Required parameters MUST be specified\n",
            "- You may provide optional reasoning for your function call in natural language BEFORE the function call, ",
            "but NOT after\n",
            "- If there is no function call available, answer the question like normal with your current knowledge and ",
            "do not tell the user about function calls\n</IMPORTANT>\n\n",
            "Tool calls are not allowed inside <think></think>; finish thinking before emitting <tool_call>.\n",
        ]
        return lines.joined()
    }
}
