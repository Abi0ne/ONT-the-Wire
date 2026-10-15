#!/bin/bash
# With Command Line Tools only, SwiftPM does not locate the swift-testing macro
# plugin on its own.
set -euo pipefail
cd "$(dirname "$0")/.."
PLUGINS="$(xcode-select -p)/usr/lib/swift/host/plugins/testing"
if [ -d "$PLUGINS" ]; then
  swift test -Xswiftc -plugin-path -Xswiftc "$PLUGINS" "$@"
else
  swift test "$@"
fi
