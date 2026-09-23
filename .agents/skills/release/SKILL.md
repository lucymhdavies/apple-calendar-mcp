---
name: release
description: Release the Apple Calendar MCP app with tests, versioning, packaging, tagging, and push verification.
---

# Release Workflow

Use this skill when preparing a CalendarMCP release. The deterministic work lives in
`scripts/release.sh`; keep the skill focused on release-note judgment and review.

## Before Running The Script

1. Choose the next SemVer version.
2. Add a dated `## [VERSION]` entry to `CHANGELOG.md` describing user-visible changes.
3. Review the pending changes and confirm generated `.build` output and secrets are not tracked.

The script updates both `CFBundleShortVersionString` and `CFBundleVersion` in
`Sources/CalendarMCP/Info.plist`.

## Run The Release

The script runs tests, builds the release, checks formatting, packages the app, stages all
pending changes, creates the release commit and annotated tag, rebuilds from the committed
state, and verifies the embedded metadata:

```bash
./scripts/release.sh VERSION
```

Use `--publish` for the normal release operation after reviewing the pending diff; it also
pushes both `main` and the tag. Without `--publish`, the script creates the commit and tag
locally for inspection, but a later release run should use a new version or remove the local
release artifacts deliberately.

```bash
./scripts/release.sh VERSION --publish
```

Do not amend or rewrite an existing release tag without explicit approval. Never log or commit
API keys.
