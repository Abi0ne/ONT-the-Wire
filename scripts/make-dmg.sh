#!/bin/bash
# Builds build/release/ONT-The-Wire-<version>.dmg: a drag-to-install disk image
# with the app, a link to /Applications and a text file explaining how to open
# an app that is not notarized.
# Usage: make-dmg.sh [app]   (default: build/ONT The Wire.app)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/Resources/Info.plist")"
APP="${1:-$ROOT/build/ONT The Wire.app}"
OUT="$ROOT/build/release"
DMG="$OUT/ONT-The-Wire-$VERSION.dmg"
README="LEGGIMI - Come aprire ONT The Wire.txt"

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

ditto "$APP" "$STAGE/ONT The Wire.app"
ln -s /Applications "$STAGE/Applicazioni"

cat > "$STAGE/$README" <<TXT
ONT The Wire $VERSION
=====================

INSTALLAZIONE
1. Trascina "ONT The Wire" sulla cartella "Applicazioni" in questa finestra.
2. Espelli l'immagine disco.

PERCHÉ macOS BLOCCA L'APP AL PRIMO AVVIO
ONT The Wire non è firmata con un certificato Apple Developer né notarizzata da
Apple. Al primo avvio macOS mostra un avviso come "Apple non può verificare che
ONT The Wire non contenga malware" e non la apre. Va autorizzata una volta sola.

COME CONSENTIRNE L'ESECUZIONE (macOS 15 Sequoia e successivi)
1. Apri ONT The Wire da Applicazioni: compare l'avviso. Premi "Fine".
2. Apri Impostazioni di Sistema › Privacy e sicurezza.
3. Nella sezione "Sicurezza" premi "Apri comunque" accanto al messaggio su
   ONT The Wire.
4. Conferma con password o Touch ID.

macOS 14 Sonoma: nel Finder fai clic destro (o Ctrl-clic) sull'app in
Applicazioni, scegli "Apri" e conferma.

ALTERNATIVA DA TERMINALE
    xattr -dr com.apple.quarantine "/Applications/ONT The Wire.app"

REQUISITI
macOS 14 o successivo, Mac con Apple Silicon, un adattatore Ethernet
(USB o Thunderbolt) collegato alla porta LAN dell'ONT.

AGGIORNAMENTI
A ogni avvio l'app controlla le nuove versioni su GitHub, verifica la firma
Ed25519 del pacchetto e propone di installarlo.

Manuale: https://github.com/Abi0ne/ONT-the-Wire/blob/main/docs/MANUALE.md
Codice sorgente e segnalazioni: https://github.com/Abi0ne/ONT-the-Wire
TXT

mkdir -p "$OUT"
rm -f "$DMG"
hdiutil create -quiet -volname "ONT The Wire" -srcfolder "$STAGE" -fs HFS+ -format UDZO \
    -imagekey zlib-level=9 "$DMG"
hdiutil verify -quiet "$DMG"
echo "$DMG"
