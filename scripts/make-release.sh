#!/bin/bash
# Builds the files of a GitHub release into build/release/:
#   ONT-The-Wire-<version>.zip       the app, installed by the automatic updates
#   ONT-The-Wire-<version>.zip.sig   Ed25519 signature of the zip (checked before installing)
#   ONT-The-Wire-<version>.dmg       drag-to-install disk image for manual downloads
# The version comes from Resources/Info.plist (CFBundleShortVersionString).
# Environment:
#   ONT_UPDATE_KEY  private signing key (default ~/.config/ontthewire/update-ed25519.key)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/Resources/Info.plist")"
KEY="${ONT_UPDATE_KEY:-$HOME/.config/ontthewire/update-ed25519.key}"
OUT="$ROOT/build/release"
SIGNING="$ROOT/scripts/update-signing.swift"
NAME="ONT-The-Wire-$VERSION"

[[ -f "$KEY" ]] || { echo "Chiave di firma non trovata: $KEY (vedi docs/BUILD.md)" >&2; exit 1; }
EMBEDDED="$(grep -m1 'static let publicKey' "$ROOT/Sources/ONTTheWireCore/Update/Updates.swift" | cut -d'"' -f2)"
[[ "$(swift "$SIGNING" public "$KEY")" == "$EMBEDDED" ]] \
    || { echo "La chiave non corrisponde alla chiave pubblica in Updates.swift" >&2; exit 1; }

"$ROOT/scripts/build-app.sh"

rm -rf "$OUT"
mkdir -p "$OUT"
ZIP="$OUT/$NAME.zip"
ditto -c -k --keepParent "$ROOT/build/ONT The Wire.app" "$ZIP"
swift "$SIGNING" sign "$KEY" "$ZIP" > "$ZIP.sig"
swift "$SIGNING" verify "$EMBEDDED" "$ZIP" "$(cat "$ZIP.sig")"
"$ROOT/scripts/make-dmg.sh" > /dev/null

echo
ls -l "$OUT"
echo
echo "Pubblica con:"
echo "  gh release create v$VERSION --repo Abi0ne/ONT-the-Wire --title \"ONT The Wire $VERSION\" --notes-file <note> $OUT/*"
