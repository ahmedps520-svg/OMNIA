// swift-tools-version: 5.10
//
// Vends llama.cpp's XCFramework (Metal backend embedded) to the OMNIA app target. Swift code
// imports it as `import llama`.
//
// Pinned build: b11960 (the build behind the llama.cpp v0.8.0 stable release, 2026-10-28), commit
// below. To upgrade, change the URL, checksum and commit together (see README.md › "Updating
// llama.cpp"), check that scripts/llama/cluster.patch still applies, then re-check
// LlamaRuntime.swift against the new include/llama.h.
//
// Shipped builds use OMNIA's own build of that commit: scripts/build-llama-xcframework.sh builds
// it with the RPC backend that cluster mode needs (and the patch that keeps a lost worker from
// ending the app), plus an iOS Simulator slice for the tests, and places it next to this file.
// CI and the TestFlight workflow run it; when that copy exists it is used. Without it, Xcode
// downloads the official release and verifies it against the checksum: everything works except
// cluster mode, which the release doesn't include.

import Foundation
import PackageDescription

let releaseURL = "https://github.com/ggml-org/llama.cpp/releases/download/b11960/llama-b11960-xcframework.zip"
let releaseChecksum = "feba05e0b7cb5e682ae3354abb455bf9723ae2cc95c69e24d073264e6a34d759"
let releaseCommit = "8642541b255bfb5dc39cd351a178be09013a55d6"

let localCopy = Context.packageDirectory + "/llama.xcframework"
let framework: Target = FileManager.default.fileExists(atPath: localCopy)
    ? .binaryTarget(name: "LlamaFramework", path: "llama.xcframework")
    : .binaryTarget(name: "LlamaFramework", url: releaseURL, checksum: releaseChecksum)

let package = Package(
    name: "LlamaFramework",
    platforms: [
        .iOS(.v17)
    ],
    products: [
        .library(name: "LlamaFramework", targets: ["LlamaFramework"])
    ],
    targets: [framework]
)
