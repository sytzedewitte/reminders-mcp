#!/bin/zsh
# Builds reminders-mcp as a single standalone binary (no dependencies outside macOS).
#   ./build.sh            -> ./bin/reminders-mcp
#   ./build.sh install    -> builds and copies to ~/.local/bin/reminders-mcp
#   REMINDERS_MCP_ARCHS="arm64 x86_64" ./build.sh  -> universal binary (used for releases)
set -euo pipefail
cd "$(dirname "$0")"

# Use the Command Line Tools if the Xcode license has not been accepted yet.
if ! xcrun --find swiftc >/dev/null 2>&1 && [[ -d /Library/Developer/CommandLineTools ]]; then
  export DEVELOPER_DIR=/Library/Developer/CommandLineTools
fi

mkdir -p bin
archs=(${=REMINDERS_MCP_ARCHS:-$(uname -m)})
slices=()
for arch in $archs; do
  xcrun swiftc -O -swift-version 5 \
    -target "${arch}-apple-macos14.0" \
    Sources/main.swift \
    -o "bin/reminders-mcp.${arch}" \
    -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker Info.plist
  slices+=("bin/reminders-mcp.${arch}")
done
if (( ${#slices} > 1 )); then
  xcrun lipo -create $slices -output bin/reminders-mcp
  rm -f $slices
else
  mv -f $slices[1] bin/reminders-mcp
fi

# Ad-hoc sign with a fixed identifier, so macOS can tie the permission to this program.
codesign --force --sign - --identifier local.reminders-mcp bin/reminders-mcp
echo "Built: $(pwd)/bin/reminders-mcp"

if [[ "${1:-}" == "install" ]]; then
  mkdir -p "$HOME/.local/bin"
  # Copy then rename, so a running server is never overwritten in place.
  cp bin/reminders-mcp "$HOME/.local/bin/.reminders-mcp.new"
  mv -f "$HOME/.local/bin/.reminders-mcp.new" "$HOME/.local/bin/reminders-mcp"
  echo "Installed:$HOME/.local/bin/reminders-mcp"
fi
