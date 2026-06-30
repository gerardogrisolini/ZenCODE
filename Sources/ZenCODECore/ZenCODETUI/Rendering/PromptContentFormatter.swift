//
//  PromptContentFormatter.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Dispatch
import Foundation

public enum PromptContentFormatter {
    public static func renderPromptText(from blocks: [Any]) -> String {
        blocks.compactMap(renderBlock).joined(separator: "\n\n")
    }
    
    private static func renderBlock(_ block: Any) -> String? {
        if let text = block as? String {
            return text
        }
        guard let object = block as? [String: Any] else {
            return compactJSONString(from: block)
        }
        
        let type = (object["type"] as? String ?? "text").lowercased()
        switch type {
        case "text":
            return object["text"] as? String
        case "resource_link", "resourcelink":
            let name = object["title"] as? String
            ?? object["name"] as? String
            ?? "resource"
            let uri = object["uri"] as? String ?? ""
            let description = object["description"] as? String
            var rendered = "Resource: \(name)"
            if !uri.isEmpty {
                rendered += "\nURI: \(uri)"
            }
            if let description,
               !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                rendered += "\nDescription: \(description)"
            }
            return rendered
        case "resource":
            guard let resource = object["resource"] as? [String: Any] else {
                return compactJSONString(from: object)
            }
            if let text = resource["text"] as? String {
                let uri = resource["uri"] as? String
                if let uri,
                   !uri.isEmpty {
                    return "Resource: \(uri)\n\n\(text)"
                }
                return text
            }
            if let blob = resource["blob"] as? String {
                let uri = resource["uri"] as? String ?? "embedded resource"
                return "Binary resource: \(uri)\nBase64 bytes: \(blob.count)"
            }
            return compactJSONString(from: object)
        case "image":
            let uri = object["uri"] as? String ?? "embedded image"
            let mimeType = object["mimeType"] as? String ?? "image"
            return "Image attachment: \(uri) (\(mimeType))"
        case "audio":
            let mimeType = object["mimeType"] as? String ?? "audio"
            return "Audio attachment: \(mimeType)"
        default:
            return compactJSONString(from: object)
        }
    }
    
    private static func compactJSONString(from value: Any) -> String? {
        JSONValue(jsonObject: value).compactString()
    }
}
