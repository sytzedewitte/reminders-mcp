#!/bin/zsh
# Bouwt reminders-mcp als één zelfstandig binair bestand (geen afhankelijkheden buiten macOS).
#   ./build.sh            -> ./bin/reminders-mcp
#   ./build.sh install    -> bouwt en kopieert naar ~/.local/bin/reminders-mcp
set -euo pipefail
cd "$(dirname "$0")"

# Gebruik de Command Line Tools als de Xcode-licentie nog niet is geaccepteerd.
if ! xcrun --find swiftc >/dev/null 2>&1 && [[ -d /Library/Developer/CommandLineTools ]]; then
  export DEVELOPER_DIR=/Library/Developer/CommandLineTools
fi

mkdir -p bin
xcrun swiftc -O -swift-version 5 \
  -target "$(uname -m)-apple-macos14.0" \
  Sources/main.swift \
  -o bin/reminders-mcp \
  -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker Info.plist

# Ad-hoc ondertekenen met vaste identifier, zodat macOS de toestemming aan dit programma kan koppelen.
codesign --force --sign - --identifier local.reminders-mcp bin/reminders-mcp
echo "Gebouwd: $(pwd)/bin/reminders-mcp"

if [[ "${1:-}" == "install" ]]; then
  mkdir -p "$HOME/.local/bin"
  cp bin/reminders-mcp "$HOME/.local/bin/reminders-mcp"
  echo "Geïnstalleerd: $HOME/.local/bin/reminders-mcp"
fi
