#!/usr/bin/env bash
#
# Builds Packages/LlamaFramework/llama.xcframework (iOS devices and the arm64 iOS Simulator) from
# the llama.cpp tag pinned in Package.swift, with OMNIA's patch for cluster mode applied
# (scripts/llama/cluster.patch): the RPC backend is built in, and a worker that drops out
# fails a request instead of ending the app.
#
# Package.swift uses this copy whenever it exists. CI builds it for the tests and the TestFlight
# workflow builds (or restores) it before archiving, so every shipped build has cluster mode. An
# Xcode build without it falls back to the official release, which has no RPC backend: OMNIA
# then works as before, with cluster mode unavailable.
#
# Usage: scripts/build-llama-xcframework.sh   (macOS with Xcode and CMake)
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
package="$root/Packages/LlamaFramework"
patch="$root/scripts/llama/cluster.patch"
url=$(sed -n 's/^let releaseURL = "\(.*\)"$/\1/p' "$package/Package.swift")
tag=$(printf '%s\n' "$url" | sed -n 's#.*/download/\([^/]*\)/.*#\1#p')
# The commit behind the tag, so a moved tag can't change what is built.
commit=$(sed -n 's/^let releaseCommit = "\(.*\)"$/\1/p' "$package/Package.swift")
if [ -z "$tag" ] || [ -z "$commit" ]; then
  echo "error: couldn't read releaseURL and releaseCommit from Package.swift" >&2
  exit 1
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

echo "Building llama.cpp $tag ($commit) with OMNIA's cluster patch"
git clone --quiet --depth 1 --branch "$tag" https://github.com/ggml-org/llama.cpp.git "$work/llama.cpp"
cd "$work/llama.cpp"
actual=$(git rev-parse HEAD)
if [ "$actual" != "$commit" ]; then
  echo "error: llama.cpp $tag is $actual, expected $commit" >&2
  exit 1
fi
git apply --verbose "$patch"

# The runners are Apple silicon, so the simulator slice only needs arm64.
sed -i '' -e 's/-DCMAKE_OSX_ARCHITECTURES="arm64;x86_64"/-DCMAKE_OSX_ARCHITECTURES="arm64"/' \
          -e 's/archs="arm64 x86_64"/archs="arm64"/' build-xcframework.sh
./build-xcframework.sh ios-device ios-sim

built="build-apple/llama.xcframework"
for slice in ios-arm64 ios-arm64-simulator; do
  if [ ! -d "$built/$slice/llama.framework" ]; then
    echo "error: the framework has no $slice slice" >&2
    exit 1
  fi
done
# The RPC backend has to be in the binary, or cluster mode would silently be missing. (The symbols
# go to a file first: grep -q stops reading early, which breaks nm's pipe under pipefail.)
nm -gU "$built/ios-arm64/llama.framework/llama" > "$work/symbols.txt"
if ! grep -q "_ggml_backend_rpc_reg" "$work/symbols.txt"; then
  echo "error: the framework was built without the RPC backend" >&2
  exit 1
fi

rm -rf "$package/llama.xcframework"
cp -R "$built" "$package/llama.xcframework"
echo "Created $package/llama.xcframework"
