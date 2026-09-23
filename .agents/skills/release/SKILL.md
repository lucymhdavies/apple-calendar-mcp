---
name: release
description: Release the Apple Calendar MCP app with tests, versioning, packaging, tagging, and push verification.
---

# Release Workflow

Use this skill when preparing a CalendarMCP release.

## Checklist

1. Confirm the worktree and recent tags:

   ```bash
   git status --short
   git log -5 --oneline --decorate
   git tag --sort=-version:refname | head
   ```

2. Choose the next SemVer version and update both `CFBundleShortVersionString` and `CFBundleVersion` in `Sources/CalendarMCP/Info.plist`.

3. Add a dated entry to `CHANGELOG.md` describing user-visible changes.

4. Run validation:

   ```bash
   swift test
   swift build -c release
   ```

5. Build the signed app bundle. The script injects the source revision, UTC build timestamp, and dirty-worktree marker:

   ```bash
   ./scripts/build-release.sh
   ```

6. Inspect the final diff and confirm only intended files are included:

   ```bash
   git diff --check
   git status --short
   ```

7. Commit the release:

   ```bash
   git add CHANGELOG.md Sources/CalendarMCP/Info.plist <intended-files>
   git commit -m "Release v<VERSION>"
   ```

8. Tag and push the commit and tag:

   ```bash
   git tag -a v<VERSION> -m "Release v<VERSION>"
   git push origin main
   git push origin v<VERSION>
   ```

9. Rebuild after the commit and verify the packaged revision is clean:

   ```bash
   ./scripts/build-release.sh
   plutil -p .build/release/CalendarMCP.app/Contents/Info.plist | grep CalendarMCPBuildRevision
   ```

10. Smoke-test MCP initialization and REST `/health` when the local services are available. Never log or commit API keys.

Do not commit generated `.build` output. Do not amend or rewrite an existing release tag without explicit approval.
