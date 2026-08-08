import Foundation

/// Collision-free aliases for host modules.
///
/// The module is named `ZenMemory`, but it also exports the `ZenMemory` actor.
/// Swift resolves `ZenMemory.MemoryEntry` as a member of the *actor*, not the
/// *module*, so the qualified form is unusable. A host module that declares its
/// own `MemoryEntry` / `MemoryScope` (e.g. ZenCODECore's public DTOs) can still
/// reach the engine types through these unambiguous typealiases.
public typealias EngineMemoryEntry = MemoryEntry
public typealias EngineMemoryScope = MemoryScope
public typealias EngineMemoryCategory = MemoryCategory
