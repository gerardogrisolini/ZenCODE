//
//  DS4ToolCallRenderer.swift
//  ZenCODE
//
//  Renders assistant tool calls in the model's native markup for transcript
//  replay, byte-compatible with the model's chat template as reproduced by
//  ds4_server.c (append_dsml_tool_calls_text, append_glm_tool_calls_text,
//  append_qwen_tool_calls_text). DS4GeneratedOutputParser parses the result
//  back to the same names and arguments.
//

import Foundation
import ToolCore

enum DS4ToolCallRenderer {
    /// The native tool-call markup for `calls`, to append right after the
    /// assistant turn's visible content.
    ///
    /// - DSML/DSML 4.1: the block always starts with the template separator
    ///   `\n\n`, one parameter per line.
    /// - GLM: inline, with no separator before or after the block.
    /// - Qwen: `\n\n` before the first call only when the turn has visible
    ///   content (`hasContent`), `\n` between calls.
    ///
    /// Arguments keep the top-level key order of `argumentsJSON`. String values
    /// use `string="true"` (DSML) or raw text; other values are minified JSON.
    /// Only the value's own closing delimiter is escaped (ds4_tool_text.h). An
    /// `argumentsJSON` that is not a JSON object is replayed as a single
    /// `arguments` string parameter, like ds4_server.c.
    static func renderToolCalls(
        _ calls: [DS4ToolCallReplay],
        syntax: DS4ToolSyntax,
        hasContent: Bool = false
    ) -> String {
        guard !calls.isEmpty else {
            return ""
        }
        switch syntax {
        case .dsml, .dsml41:
            return renderDSML(calls, syntax: syntax)
        case .glm:
            return renderGLM(calls)
        case .qwen:
            return renderQwen(calls, hasContent: hasContent)
        }
    }

    // MARK: - DSML

    private static func renderDSML(_ calls: [DS4ToolCallReplay], syntax: DS4ToolSyntax) -> String {
        let parameterClose = syntax.parameterCloseMarker
        var output = "\n\n" + syntax.dsmlOpenTag(.toolCalls) + ">\n"
        for call in calls {
            output += syntax.dsmlOpenTag(.invoke) + " name=\"" + DS4ToolTextEscaping.escapeAttribute(call.name) + "\">\n"
            if let members = DS4JSONText.orderedMembers(call.argumentsJSON) {
                for member in members {
                    let isString: Bool
                    let body: String
                    if case let .string(text) = member.value {
                        isString = true
                        body = DS4ToolTextEscaping.escape(text, closingTag: parameterClose)
                    } else {
                        isString = false
                        body = jsonLiteral(member.minifiedJSON, closingTag: parameterClose)
                    }
                    output += syntax.dsmlOpenTag(.parameter)
                        + " name=\"" + DS4ToolTextEscaping.escapeAttribute(member.key)
                        + "\" string=\"" + (isString ? "true" : "false") + "\">"
                        + body + parameterClose + "\n"
                }
            } else {
                output += syntax.dsmlOpenTag(.parameter) + " name=\"arguments\" string=\"true\">"
                    + DS4ToolTextEscaping.escape(call.argumentsJSON, closingTag: parameterClose)
                    + parameterClose + "\n"
            }
            output += syntax.dsmlCloseTag(.invoke) + "\n"
        }
        output += syntax.dsmlCloseTag(.toolCalls)
        return output
    }

    /// `append_dsml_json_literal`: a closing tag inside JSON text (only
    /// possible inside a JSON string) gets its `<` written as `\u003c`.
    private static func jsonLiteral(_ json: String, closingTag: String) -> String {
        guard json.contains(closingTag) else {
            return json
        }
        return json.replacingOccurrences(of: closingTag, with: "\\u003c" + closingTag.dropFirst())
    }

    // MARK: - GLM

    private static func renderGLM(_ calls: [DS4ToolCallReplay]) -> String {
        var output = ""
        for call in calls {
            output += "<tool_call>" + call.name
            if let members = DS4JSONText.orderedMembers(call.argumentsJSON) {
                for member in members {
                    output += "<arg_key>" + DS4ToolTextEscaping.escape(member.key, closingTag: "</arg_key>")
                        + "</arg_key><arg_value>"
                        + DS4ToolTextEscaping.escape(textOrJSON(member), closingTag: "</arg_value>")
                        + "</arg_value>"
                }
            } else {
                output += "<arg_key>arguments</arg_key><arg_value>"
                    + DS4ToolTextEscaping.escape(call.argumentsJSON, closingTag: "</arg_value>")
                    + "</arg_value>"
            }
            output += "</tool_call>"
        }
        return output
    }

    // MARK: - Qwen

    private static func renderQwen(_ calls: [DS4ToolCallReplay], hasContent: Bool) -> String {
        var output = ""
        for (index, call) in calls.enumerated() {
            if index == 0 {
                output += hasContent ? "\n\n<tool_call>\n<function=" : "<tool_call>\n<function="
            } else {
                output += "\n<tool_call>\n<function="
            }
            output += call.name + ">\n"
            if let members = DS4JSONText.orderedMembers(call.argumentsJSON) {
                for member in members {
                    output += "<parameter=" + member.key + ">\n"
                        + DS4ToolTextEscaping.escape(textOrJSON(member), closingTag: "</parameter>")
                        + "\n</parameter>\n"
                }
            } else if !call.argumentsJSON.isEmpty {
                output += "<parameter=arguments>\n"
                    + DS4ToolTextEscaping.escape(call.argumentsJSON, closingTag: "</parameter>")
                    + "\n</parameter>\n"
            }
            output += "</function>\n</tool_call>"
        }
        return output
    }

    private static func textOrJSON(_ member: DS4JSONText.Member) -> String {
        if case let .string(text) = member.value {
            return text
        }
        return member.minifiedJSON
    }
}
