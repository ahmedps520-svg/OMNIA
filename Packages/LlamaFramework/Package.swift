// swift-tools-version: 5.10
//
// Vends the official llama.cpp XCFramework (Metal backend embedded) to the OMNIA app target.
// The binary is the prebuilt release artifact published by ggml-org; Xcode downloads it once
// and verifies it against the checksum below. Swift code imports it as `import llama`.
//
// Pinned build: b11960 (the build behind the llama.cpp v0.8.0 stable release, 2026-10-28).
// To upgrade, change the URL and checksum together (see README.md › "Updating llama.cpp"),
// then re-check LlamaRuntime.swift against the new include/llama.h.
//
// The release has no iOS Simulator slice. For the unit tests, CI runs
// scripts/build-llama-xcframework.sh, which places a copy with a simulator slice built from the
// same tag next to this file. When that copy exists it is used instead of the download.

import Foundation
import PackageDescription

let releaseURL = "https://github.com/ggml-org/llama.cpp/releases/download/b11960/llama-b11960-xcframework.zip"
let releaseChecksum = "feba05e0b7cb5e682ae3354abb455bf9723ae2cc95c69e24d073264e6a34d759"

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
