#!/bin/zsh
# Builds reminders-mcp as a single standalone binary (no dependencies outside macOS).
#   ./build.sh            -> ./bin/reminders-mcp
#   ./build.sh install    -> builds and copies to ~/.local/bin/reminders-mcp
set -euo pipefail
cd "$(dirname "$0")"

# Use the Command Line Tools if the Xcode license has not been accepted yet.
if ! xcrun --find swiftc >/dev/null 2>&1 && [[ -d /Library/Developer/CommandLineTools ]]; then
  export DEVELOPER_DIR=/Library/Developer/CommandLineTools
fi

mkdir -p bin
xcrun swiftc -O -swift-version 5 \
  -target "$(uname -m)-apple-macos14.0" \
  Sources/main.swift \
  -o bin/reminders-mcp \
  -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker Info.plist

# Ad-hoc sign with a fixed identifier, so macOS can tie the permission to this program.
codesign --force --sign - --identifier local.reminders-mcp bin/reminders-mcp
echo "Built: $(pwd)/bin/reminders-mcp"

if [[ "${1:-}" == "install" ]]; then
  mkdir -p "$HOME/.local/bin"
  cp bin/reminders-mcp "$HOME/.local/bin/reminders-mcp"
  echo "Installed:$HOME/.local/bin/reminders-mcp"
fi
