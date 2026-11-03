//
//  ZenAppTranscript.swift
//  ZenApp
//
//  Leaf views of the conversation transcript: prompts, assistant text,
//  thinking, tool calls, notices, file changes, task-graph and sub-agent
//  cards, and the welcome view. Every view reads its colors from `ZenPalette`
//  (the terminal UI's palette) and renders Markdown through the injectable
//  `ZenMarkdownRenderer` environment value.
//

import Foundation

/// Namespace marker of the `ZenAppTranscript` module.
public enum ZenAppTranscriptModule {}
