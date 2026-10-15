#!/bin/bash
# Builds build/ONT The Wire.app from the Swift package (Command Line Tools are
# enough; Xcode is not required) and signs it ad hoc for local use.
set -euo pipefail

cd "$(dirname "$0")/.."
CONFIG="${1:-release}"
APP="build/ONT The Wire.app"

swift build -c "$CONFIG" --product ONTTheWire
swift build -c "$CONFIG" --product pppoe-relay
swift build -c "$CONFIG" --product ont-root-helper
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/ONTTheWire" "$APP/Contents/MacOS/ONTTheWire"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"   # from scripts/make-icon.swift
# Root side (one authorization per app run): helper, broker, per-session
# supervisor and the PPPoE transport.
install -m 755 "$BIN_DIR/ont-root-helper" "$APP/Contents/Resources/ont-root-helper"
install -m 755 Resources/ont-broker.sh "$APP/Contents/Resources/ont-broker.sh"
install -m 755 Resources/ont-session.sh "$APP/Contents/Resources/ont-session.sh"
install -m 755 "$BIN_DIR/pppoe-relay" "$APP/Contents/Resources/pppoe-relay"

# Hardened runtime, no sandbox: the session needs raw access to the network
# interface (BPF) and runs pppd as root.
codesign --force --options runtime --sign - "$APP"

echo "Creato: $APP"
