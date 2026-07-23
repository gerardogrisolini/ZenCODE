# Persisted credential security

## Current protection

ZenCODE persists provider API keys, subscription credentials, Telegram settings,
and durable command approvals in its application support manifests. The storage
boundary is centralized in
`Sources/ZenCODECore/Shared/Services/SensitiveFilePermissions.swift`.

On macOS, Linux, and WSL, that boundary applies the following protections to
`settings.json`, `permissions.json`, and `agents.json`:

- creates or normalizes the containing application-support directory to Unix
  mode `0700`;
- creates the temporary file at mode `0600` **before** manifest bytes are
  written, synchronizes it, then atomically renames it into place;
- normalizes an existing manifest and its containing directory on successful
  load, providing a permissions-only migration for installations created by
  older releases;
- refuses symbolic links and unexpected filesystem node types for sensitive
  files or their containing directory, rather than following a link and
  changing an unrelated target's permissions;
- preserves the existing JSON filenames, schema, and setup/provider flows.

Failures to apply required POSIX permissions cause the corresponding sensitive
manifest operation to fail rather than silently accepting a known weak mode.
No credential values are logged by this layer.

## Scope and limits

This is filesystem hardening, not encryption and not an operating-system
credential vault. The manifest payload remains plaintext for the owning user
and for any principal that can act as that user (or as an administrator/root).
Filesystem ACLs, backups, synchronized folders, and an unencrypted host volume
can impose additional exposure outside these mode bits.

ZenCODE deliberately does not simulate a secret store. Using Keychain,
libsecret, or a platform credential manager directly would introduce
platform-specific behavior or dependencies that are not currently available to
the shared macOS/Linux/WSL runtime. The centralized filesystem boundary is the
migration seam for a future real vault: a platform adapter can store credential
material there while manifests retain compatible non-secret references. Until
that exists, restrictive filesystem permissions are the concrete portable
fallback.
