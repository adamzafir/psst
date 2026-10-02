#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
APP="$PWD/build/Psst.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Psst "$APP/Contents/MacOS/Psst"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# Stable designated requirement keeps the local app's identity consistent on rebuild.
codesign --force --sign - --identifier com.adamzafir.psst \
  --requirements '=designated => identifier "com.adamzafir.psst"' "$APP"
if [[ "${1:-}" == "--install" ]]; then
  mkdir -p "$HOME/Applications"
  ditto "$APP" "$HOME/Applications/Psst.app"
  echo "Installed $HOME/Applications/Psst.app"
else
  echo "Built $APP"
fi
