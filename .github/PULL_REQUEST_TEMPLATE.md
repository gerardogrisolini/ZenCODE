## Summary

<!-- What does this change do, and why? -->

## Related issue

<!-- e.g. Closes #123 -->

## Validation

<!-- Check what you ran locally. CI runs the same gate on macOS and Linux. -->

- [ ] `swift build --target ZenCODECore`
- [ ] `swift test`
- [ ] `swift build -c release --product zen`
- [ ] `bash -n Scripts/*.sh`
- [ ] `git diff --check`

## Compatibility

<!--
Does this change public modules, executable names, wire formats, persisted
formats, feature identities, or task-graph ownership? If so, describe the
migration. See Docs/architecture.md.
-->

- [ ] No compatibility impact
- [ ] Compatibility impact described above

## Checklist

- [ ] Tests added or updated (Swift Testing)
- [ ] Docs updated (`Docs/`, `AGENTS.md`) if a boundary, path, or gate moved
- [ ] `CHANGELOG.md` updated under `## [Unreleased]` for user-visible changes
- [ ] `Package.resolved` unchanged, or intentionally updated and reviewed
