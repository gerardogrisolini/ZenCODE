//
//  MemoryGraphTarget.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 20/10/26.
//
//  Names which MemoryEngine graph a memory operation addresses.
//

import Foundation

/// The persisted graph a memory operation reads from or writes to.
///
/// Both cases share the same store, registry, and on-disk format: they differ
/// only in the file they resolve to (see `MemoryGraphLocation`).
public enum MemoryGraphTarget: Hashable, Sendable {
    /// The graph owned by one workspace, keyed by the digest of its root path.
    case workspace(URL)
    /// The single graph shared by every workspace on the machine, independent
    /// of the current working directory.
    case global
}

extension MemoryGraphTarget {
    /// The graph a session addresses: the global one for a profile whose role
    /// uses global memory, the working directory's workspace graph for every
    /// other role and when no profile is selected.
    public static func resolved(
        profileRole: AgentProfileRole?,
        workingDirectory: URL
    ) -> MemoryGraphTarget {
        profileRole?.usesGlobalMemory == true
            ? .global
            : .workspace(workingDirectory.standardizedFileURL)
    }
}
