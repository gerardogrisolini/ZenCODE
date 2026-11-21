//
//  ZenCODERuntimeReexport.swift
//  ZenCODE
//
//  ZenCODECore is the terminal UI, the interactive setup, ACP and the CLI
//  launcher composed over ZenCODERuntime, the shared runtime. Re-exporting the
//  runtime keeps `import ZenCODECore` a superset of it: every public symbol
//  that ZenCODECore exposed before the runtime became its own module is still
//  visible to its importers, with the same name, signature and isolation.
//  Integrators that need no terminal UI, setup or ACP can import
//  ZenCODERuntime alone.
//
//  The re-export is for importers of ZenCODECore only. Inside this module
//  every file that uses ZenCODERuntime still imports it explicitly
//  (`MemberImportVisibility`).
//

@_exported import ZenCODERuntime
