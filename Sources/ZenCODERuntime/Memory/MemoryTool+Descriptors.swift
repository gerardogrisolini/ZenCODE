//
//  MemoryTool+Descriptors.swift
//  ZenCODE
//
//  The memory tool descriptors and their JSON input schemas.
//

import ToolCore

extension MemoryTool {
    private static let readDescriptor = ToolDescriptor(
            name: "memory.read",
            title: "Memory Read",
            description: "Reads durable project journal entries, newest first. Use detail=index for compact Summary/timestamp/ID results before loading full content; offset pages through the journal (hasMore tells whether entries remain), and tags (all required) or category narrow it.",
            inputSchema: """
            {
              "type": "object",
              "properties": {
                "includeArchived": { "type": "boolean" },
                "limit": { "type": "number" },
                "offset": { "type": "number" },
                "detail": { "type": "string", "enum": ["full", "index"] },
                "tags": { "type": "array", "items": { "type": "string" } },
                "category": {
                  "type": "string",
                  "enum": ["fact", "preference", "entity", "correction"]
                }
              }
            }
            """,
            presentation: .standard(
                title: "Project memory",
                action: "Read",
                kind: .read
            )
        )

    private static let searchDescriptor = ToolDescriptor(
            name: "memory.search",
            title: "Memory Search",
            description: "Searches the durable project journal: BM25 keyword ranking, semantic similarity when an embedding endpoint is configured, and graph-related entries. Results are ranked by relevance; limit (1-50, default 8) caps them, includeArchived reserves up to half of the limit for archived matches, and tags (all required) or category narrow them.",
            inputSchema: """
            {
              "type": "object",
              "properties": {
                "query": { "type": "string" },
                "includeArchived": { "type": "boolean" },
                "limit": { "type": "number" },
                "detail": { "type": "string", "enum": ["full", "index"] },
                "tags": { "type": "array", "items": { "type": "string" } },
                "category": {
                  "type": "string",
                  "enum": ["fact", "preference", "entity", "correction"]
                }
              },
              "required": ["query"]
            }
            """,
            presentation: .standard(
                title: "Project memory",
                action: "Search",
                kind: .search,
                targetKeyPaths: ["query"]
            )
        )

    private static let getDescriptor = ToolDescriptor(
            name: "memory.get",
            title: "Memory Get",
            description: "Returns one durable journal entry by id with its full content and metadata, whether active or archived.",
            inputSchema: """
            {
              "type": "object",
              "properties": {
                "id": { "type": "string" }
              },
              "required": ["id"]
            }
            """,
            presentation: .standard(
                title: "Memory entry",
                action: "Get",
                kind: .read,
                targetKeyPaths: ["id"]
            )
        )

    private static let writeDescriptor = ToolDescriptor(
            name: "memory.write",
            title: "Memory Write",
            description: "Adds a concise durable project-journal entry for a verified handoff, decision, blocker, or published release. Include Summary, State, Next, and publication evidence when relevant; Timestamp is added when missing and active duplicates are reused. The result lists active entries that overlap the new one (similar) so you can consolidate with memory.update instead of keeping two notes on one fact, and existing tags related to any new tag (tagHints): reuse existing tags so related entries stay linked.",
            inputSchema: """
            {
              "type": "object",
              "properties": {
                "content": { "type": "string" },
                "tags": { "type": "array", "items": { "type": "string" } },
                "category": {
                  "type": "string",
                  "enum": ["fact", "preference", "entity", "correction"]
                }
              },
              "required": ["content"]
            }
            """,
            presentation: .standard(
                title: "Project memory",
                action: "Write",
                kind: .edit
            )
        )

    private static let updateDescriptor = ToolDescriptor(
            name: "memory.update",
            title: "Memory Update",
            description: "Updates an existing durable journal entry in place instead of duplicating changed facts. Its id, creation date, and archive state remain stable; Timestamp is preserved and Updated is stamped with the time of the update.",
            inputSchema: """
            {
              "type": "object",
              "properties": {
                "id": { "type": "string" },
                "content": { "type": "string" },
                "tags": { "type": "array", "items": { "type": "string" } }
              },
              "required": ["id", "content"]
            }
            """,
            presentation: .standard(
                title: "Memory entry",
                action: "Update",
                kind: .edit,
                targetKeyPaths: ["id"]
            )
        )

    private static let archiveDescriptor = ToolDescriptor(
            name: "memory.archive",
            title: "Memory Archive",
            description: "Archives a stale, incorrect, or no-longer-useful journal entry by id. It stops influencing retrieval and resume context but is not deleted; memory.restore brings it back.",
            inputSchema: """
            {
              "type": "object",
              "properties": {
                "id": { "type": "string" }
              },
              "required": ["id"]
            }
            """,
            presentation: .standard(
                title: "Memory entry",
                action: "Archive",
                kind: .delete,
                targetKeyPaths: ["id"]
            )
        )

    private static let restoreDescriptor = ToolDescriptor(
            name: "memory.restore",
            title: "Memory Restore",
            description: "Restores an archived journal entry by id so it takes part in retrieval and automatic recall again.",
            inputSchema: """
            {
              "type": "object",
              "properties": {
                "id": { "type": "string" }
              },
              "required": ["id"]
            }
            """,
            presentation: .standard(
                title: "Memory entry",
                action: "Restore",
                kind: .edit,
                targetKeyPaths: ["id"]
            )
        )

    /// Core memory descriptors that do not mutate durable project memory.
    public static let readOnlyToolDescriptors: [ToolDescriptor] = [
        readDescriptor,
        searchDescriptor,
        getDescriptor
    ]

    /// Core memory descriptors that can mutate durable project memory.
    public static let mutatingToolDescriptors: [ToolDescriptor] = [
        writeDescriptor,
        updateDescriptor,
        archiveDescriptor,
        restoreDescriptor
    ]

    public static let toolDescriptors: [ToolDescriptor] = [
        readDescriptor,
        searchDescriptor,
        getDescriptor,
        writeDescriptor,
        updateDescriptor,
        archiveDescriptor,
        restoreDescriptor
    ]
}
