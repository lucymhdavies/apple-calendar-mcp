#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
PLIST="$ROOT_DIR/Sources/CalendarMCP/Info.plist"
CHANGELOG="$ROOT_DIR/CHANGELOG.md"
PUBLISH=false
VERSION=""

usage() {
	printf 'Usage: %s VERSION [--publish]\n' "$0"
	printf '\nPrepare, commit, tag, and optionally publish a CalendarMCP release.\n'
}

for argument in "$@"; do
	case "$argument" in
		--publish)
			PUBLISH=true
			;;
		-h|--help)
			usage
			exit 0
			;;
		-*)
			printf 'Unknown option: %s\n' "$argument" >&2
			usage >&2
			exit 2
			;;
		*)
			if test -n "$VERSION"; then
				printf 'Only one version may be specified.\n' >&2
				exit 2
			fi
			VERSION=$argument
			;;
	esac
done

if test -z "$VERSION"; then
	usage >&2
	exit 2
fi

case "$VERSION" in
	[0-9]*.[0-9]*.[0-9]*) ;;
	*)
		printf 'Version must be SemVer, for example 0.1.7: %s\n' "$VERSION" >&2
		exit 2
		;;
esac

cd "$ROOT_DIR"

if test "$(git branch --show-current)" != "main"; then
	printf 'Releases must be made from the main branch.\n' >&2
	exit 1
fi

if git rev-parse "v$VERSION" >/dev/null 2>&1; then
	printf 'Tag already exists: v%s\n' "$VERSION" >&2
	exit 1
fi

if ! grep -Fq "## [$VERSION]" "$CHANGELOG"; then
	printf 'CHANGELOG.md is missing a ## [%s] entry.\n' "$VERSION" >&2
	exit 1
fi

plutil -replace CFBundleShortVersionString -string "$VERSION" "$PLIST"
plutil -replace CFBundleVersion -string "$VERSION" "$PLIST"

printf 'Running tests...\n'
swift test
printf 'Building release binary...\n'
swift build -c release
printf 'Checking diff...\n'
git diff --check
printf 'Building app bundle...\n'
./scripts/build-release.sh

printf 'Pending release changes:\n'
git status --short
printf 'Staging all release changes and creating v%s.\n' "$VERSION"
git add -A
git diff --cached --check
git commit -m "Release v$VERSION"
git tag -a "v$VERSION" -m "Release v$VERSION"

printf 'Rebuilding from committed release...\n'
./scripts/build-release.sh
plutil -p .build/release/CalendarMCP.app/Contents/Info.plist | grep -E 'CFBundleShortVersionString|CFBundleVersion|CalendarMCPBuildRevision'

if test "$PUBLISH" = true; then
	git push origin main
	git push origin "v$VERSION"
	printf 'Published v%s.\n' "$VERSION"
else
	printf 'Created v%s locally. Run with --publish to push main and the tag.\n' "$VERSION"
fi
