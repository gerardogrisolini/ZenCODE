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

`settings.json`, `agents.json`, and the other remote-reset writers additionally
share the cross-process `.manifests.lock` coordination boundary. Setup
prevalidates and serializes both payloads, verifies that neither manifest changed
since the interactive session began, and durably publishes a restrictive
transaction journal before replacement. Transactional renames and unlinks are
ordered with `fsync` on the parent directory. The journal is rollback-first:
until its unlink is durable, interrupted or failed work can only restore the
original bytes. Reported errors use byte-level CAS so they restore only files
still owned by that transaction. Delegation reads settings and
profiles under the same lock, so it observes one recovered generation. The
filesystem still supplies atomic rename per file rather than a native multi-file
rename primitive; lock, compare-and-swap, and journal recovery provide the
multi-file protocol.

Failures to apply required POSIX permissions cause the corresponding sensitive
manifest operation to fail rather than silently accepting a known weak mode.
No credential values are logged by this layer.

## Backup archives

The setup **Data management** export writes the entire support directory to a
single gzip-compressed tar archive. That archive is subject to the same plaintext limitation
described above: it contains provider API keys, tokens, and permissions
exactly as stored on disk, and gzip compression is not encryption. Export and
import prompts state this explicitly and print every path involved. Imported
payload files are recreated at mode `0600`, symlink entries are rejected, and
the import validates every entry's size and SHA-256 checksum before the
support directory is atomically replaced, with automatic restoration of the
previous directory on any failure. The export refuses to archive a support
directory that contains a symbolic link rather than silently skipping it, and
both export and import run under the shared `.manifests.lock` boundary; the
import's directory swap hard-links that lock so its inode — and therefore
cross-process mutual exclusion — survives the rename. Manifest size sums are
computed with overflow-checked arithmetic, so a crafted manifest cannot wrap
a `UInt64` total to slip under the size limit.

## Scope and limits

This is filesystem hardening, not encryption and not an operating-system
credential vault. Manifest payloads—and, while a coordinated update is pending,
the restrictive recovery journal—remain plaintext for the owning user and for
any principal that can act as that user (or as an administrator/root).
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
