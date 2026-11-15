#!/bin/bash
# update-local.sh — Pull the latest OpenCloud desktop (upstream main), build this
# fork with Craft, sign it with the local Apple Development identity and install it.
#
#   tools/update-local.sh              # merge upstream, test, build, sign, install
#   tools/update-local.sh --no-merge   # rebuild and install the current checkout
#
# Stops on merge conflicts or failing tests; nothing is installed in that case.
# The previously installed app is kept in ~/Applications/OpenCloud-backup/.
set -euo pipefail

REPO=$(cd "$(dirname "$0")/.." && pwd)
CRAFT_ROOT="${OPENCLOUD_CRAFT_ROOT:-$HOME/craft/CraftMaster/macos-clang-arm64}"
BUILD_DIR="$CRAFT_ROOT/build/opencloud/opencloud-desktop/work/build"
BACKUP_DIR="$HOME/Applications/OpenCloud-backup"
MERGE=true
[ "${1:-}" = "--no-merge" ] && MERGE=false

step() { echo; echo "==> $1"; }
fail() { echo "ERROR: $1" >&2; exit 1; }

SIGN_ID="${OPENCLOUD_SIGN_ID:-$(security find-identity -v -p codesigning | sed -n 's/.*"\(Apple Development: [^"]*\)".*/\1/p' | head -1)}"
[ -n "$SIGN_ID" ] || fail "No Apple Development identity found (Xcode > Settings > Accounts > Manage Certificates)"
TEAM_ID="${OPENCLOUD_TEAM_ID:-$(security find-certificate -c "$SIGN_ID" -p | openssl x509 -noout -subject | sed -n 's/.*OU=\([A-Z0-9]*\).*/\1/p')}"
[ -n "$TEAM_ID" ] || fail "Could not read the team ID from $SIGN_ID"
echo "Signing as $SIGN_ID (team $TEAM_ID)"

cd "$REPO"
[ -z "$(git status --porcelain)" ] || fail "Working tree has uncommitted changes"

if $MERGE; then
    step "Merging latest OpenCloud (upstream/main)"
    git remote get-url upstream >/dev/null 2>&1 || git remote add upstream https://github.com/opencloud-eu/desktop.git
    git fetch --quiet upstream
    OLD_SHELF=$(git rev-parse HEAD:.craft.shelf)
    if ! git merge --no-edit upstream/main; then
        fail "Merge conflicts. Resolve them (git status), commit, then run: tools/update-local.sh --no-merge"
    fi
    [ "$OLD_SHELF" = "$(git rev-parse HEAD:.craft.shelf)" ] || SHELF_CHANGED=true
fi

step "FileProvider extension tests"
for t in database webdav trash actions search status sockets; do
    printf "  %-9s" "$t"
    bash "tools/test-fileprovider-$t.sh" >/dev/null 2>&1 && echo OK || fail "tools/test-fileprovider-$t.sh failed"
done

export GITHUB_WORKSPACE="$REPO" CRAFT_TARGET=macos-clang-arm64 CMAKE_BUILD_PARALLEL_LEVEL=$(sysctl -n hw.ncpu)
export APPLE_DEVELOPMENT_TEAM_ID="$TEAM_ID" SOCKETAPI_TEAM_IDENTIFIER_PREFIX="$TEAM_ID."
craft() { pwsh .github/workflows/.craft.ps1 -c "$@"; }

if [ "${SHELF_CHANGED:-false}" = true ] || [ ! -f "$BUILD_DIR/build.ninja" ]; then
    step "Updating Craft dependencies (OpenCloud changed its pinned versions)"
    craft --unshelve .craft.shelf
    craft --install-deps opencloud/opencloud-desktop
fi

step "Building"
craft --set "srcDir=$REPO" opencloud/opencloud-desktop
craft --set 'args=-DBUILD_TESTING=OFF -DBUILD_SHELL_INTEGRATION=ON' opencloud/opencloud-desktop
if [ -f "$BUILD_DIR/build.ninja" ]; then
    (cd "$BUILD_DIR" && PATH="$CRAFT_ROOT/bin:$CRAFT_ROOT/dev-utils/bin:$PATH" ninja)
else
    craft --no-cache --fetch --unpack --configure --compile opencloud/opencloud-desktop
fi

step "Bundling and signing"
SHIP_LOG=$(mktemp)
bash tools/ship.sh --craft-root "$CRAFT_ROOT" --build-app "$BUILD_DIR/bin/OpenCloud.app" \
    --team-id "$TEAM_ID" --sign-id "$SIGN_ID" --skip-notarize | tee "$SHIP_LOG"
STAGE_APP="$(dirname "$(sed -n 's/^  Created: //p' "$SHIP_LOG" | tail -1)")/OpenCloud.app"
[ -d "$STAGE_APP" ] || fail "Signed app not found"
codesign --verify --deep --strict "$STAGE_APP"

step "Installing"
osascript -e 'tell application "OpenCloud" to quit' 2>/dev/null || true
for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -x OpenCloud >/dev/null || break; sleep 1; done
mkdir -p "$BACKUP_DIR"
if [ -d /Applications/OpenCloud.app ]; then
    rm -rf "$BACKUP_DIR/OpenCloud-previous.app"
    mv /Applications/OpenCloud.app "$BACKUP_DIR/OpenCloud-previous.app"
fi
ditto "$STAGE_APP" /Applications/OpenCloud.app
open /Applications/OpenCloud.app
echo
echo "Installed $(defaults read /Applications/OpenCloud.app/Contents/Info CFBundleShortVersionString) from $(git rev-parse --short HEAD)."
echo "Previous version: $BACKUP_DIR/OpenCloud-previous.app"
