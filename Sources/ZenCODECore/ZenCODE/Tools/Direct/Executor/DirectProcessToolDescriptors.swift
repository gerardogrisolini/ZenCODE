//
//  DirectProcessToolDescriptors.swift
//  ZenCODE
//

import Foundation
import ToolCore

enum DirectProcessTools {
#if canImport(Darwin) || canImport(Glibc)
    static let descriptors: [DirectToolDescriptor] = [
        DirectToolDescriptor(
            name: "local.exec",
            description: "Runs a shell command in the working directory and returns stdout, stderr, and exit code. Set background=true to start a long-running command (dev server, watcher, tail) as a background job and return its job id immediately; manage it with exec.job. Reserve this for commands not covered by dedicated file, text, search, Git, web, memory, or feature tools.",
            inputSchema: #"{"type":"object","properties":{"command":{"type":"string"},"cwd":{"type":"string"},"workingDirectory":{"type":"string"},"background":{"type":"boolean","description":"Start the command as a background job and return a job id immediately."},"timeoutSeconds":{"type":"number"},"timeout":{"type":"number"}},"required":["command"]}"#,
            presentation: .standard(
                title: "Command",
                action: "Run",
                kind: .execute,
                targetKeyPaths: ["command"],
                targetFormat: .command
            )
        ),
        DirectToolDescriptor(
            name: "exec.job",
            description: "Manages background jobs started by local.exec with background=true. action=poll returns job status plus new output since offset; action=kill terminates a job; action=list lists known jobs.",
            inputSchema: #"{"type":"object","properties":{"action":{"type":"string","enum":["poll","kill","list"]},"id":{"type":"string"},"jobID":{"type":"string"},"job_id":{"type":"string"},"offset":{"type":"number","description":"Byte offset returned by the previous poll; only newer output is returned."}},"required":["action"]}"#,
            presentation: .standard(
                title: "Background job",
                action: "Manage",
                kind: .manage,
                targetKeyPaths: ["id", "jobID", "job_id", "action"]
            )
        )
    ]
#endif
}
