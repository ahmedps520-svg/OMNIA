#!/usr/bin/env bash
#
# Builds Packages/LlamaFramework/llama.xcframework for the unit tests on CI.
#
# The llama.cpp release XCFramework has device and macOS slices but no iOS Simulator slice, so
# the simulator-hosted unit tests can't link it. This script verifies the release archive pinned
# in Package.swift, compiles an arm64 simulator slice from the same llama.cpp tag with llama.cpp's
# own build-xcframework.sh, and combines it with the release's device slice. Package.swift uses
# this local copy when it exists. Release and TestFlight builds never run this script, so they
# keep using the release artifact unchanged.
#
# Usage: scripts/build-llama-xcframework.sh   (macOS with Xcode and CMake)
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
package="$root/Packages/LlamaFramework"
url=$(sed -n 's/^let releaseURL = "\(.*\)"$/\1/p' "$package/Package.swift")
checksum=$(sed -n 's/^let releaseChecksum = "\(.*\)"$/\1/p' "$package/Package.swift")
tag=$(printf '%s\n' "$url" | sed -n 's#.*/download/\([^/]*\)/.*#\1#p')
if [ -z "$url" ] || [ -z "$checksum" ] || [ -z "$tag" ]; then
  echo "error: couldn't read releaseURL and releaseChecksum from Package.swift" >&2
  exit 1
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

echo "Downloading and verifying $url"
curl -fsSL -o "$work/release.zip" "$url"
echo "$checksum  $work/release.zip" | shasum -a 256 -c -
unzip -q "$work/release.zip" -d "$work/release"
device=$(find "$work/release" -type d -path "*/ios-arm64/llama.framework" | head -n 1)

echo "Building the iOS Simulator slice from llama.cpp $tag"
git clone --quiet --depth 1 --branch "$tag" https://github.com/ggml-org/llama.cpp.git "$work/llama.cpp"
cd "$work/llama.cpp"
# The runners are Apple silicon, so the simulator slice only needs arm64.
sed -i '' -e 's/-DCMAKE_OSX_ARCHITECTURES="arm64;x86_64"/-DCMAKE_OSX_ARCHITECTURES="arm64"/' \
          -e 's/archs="arm64 x86_64"/archs="arm64"/' build-xcframework.sh
./build-xcframework.sh ios-sim
simulator=$(find build-apple/llama.xcframework -type d -path "*simulator/llama.framework" | head -n 1)

if [ -z "$device" ] || [ -z "$simulator" ]; then
  echo "error: missing a framework slice (device: '$device', simulator: '$simulator')" >&2
  exit 1
fi
rm -rf "$package/llama.xcframework"
xcodebuild -create-xcframework -framework "$device" -framework "$simulator" -output "$package/llama.xcframework"
echo "Created $package/llama.xcframework"
