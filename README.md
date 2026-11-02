# OMNIA

**Every model. One mind.**

OMNIA is a private, local-first AI workstation for **iPad Pro (M5)** and **iPhone 18 Pro**. It downloads open-weight language models once, then runs them entirely on the device's GPU through Metal: no account, no cloud inference, no telemetry. After a model is downloaded, chat works with no network at all.

Native Swift and SwiftUI throughout. The inference engine is [llama.cpp](https://github.com/ggml-org/llama.cpp) (GGUF models, Metal backend), linked as the official prebuilt XCFramework.

---

## Contents

1. [Requirements](#requirements)
2. [Build and run](#build-and-run)
3. [TestFlight](#testflight)
4. [What's inside](#whats-inside)
5. [How models are chosen and loaded](#how-models-are-chosen-and-loaded)
6. [Model catalog](#model-catalog)
7. [Privacy](#privacy)
8. [Known limits](#known-limits)
9. [Maintenance](#maintenance)

---

## Requirements

| | |
|---|---|
| Mac | macOS with **Xcode 26 or later** (Xcode 27.2 current as of November 2026) |
| Account | Paid Apple Developer Program membership (for device builds and TestFlight) |
| Devices | iPad Pro 11″/13″ (M5) — `iPad17,1`–`iPad17,4` · iPhone 18 Pro — `iPhone19,2` · iPhone 18 Pro Max — `iPhone19,3`, `iPhone19,7` |
| OS | iPadOS / iOS 26.0 or later |

Other hardware sees an "unsupported device" screen in Release builds (Debug builds and the Simulator can continue for development). Model identifiers come from AppleDB, EveryMac and The Apple Wiki; Apple doesn't publish them.

**No Mac?** The included GitHub Actions workflows build, test and upload to TestFlight on GitHub's macOS runners — see [TestFlight › Without a Mac](#without-a-mac).

## Build and run

1. Open `OMNIA.xcodeproj` in Xcode. Swift packages resolve automatically:
   - `Packages/LlamaFramework` — the llama.cpp **b11960** XCFramework (the build behind llama.cpp v0.8.0), checksum-verified.
   - `swift-jinja` (Hugging Face) — renders each model's own chat template.
2. Edit `Config/Signing.xcconfig`:
   ```
   DEVELOPMENT_TEAM = ABCDE12345
   OMNIA_BUNDLE_ID_PREFIX = com.yourname
   ```
   (Or pick your team in the target's *Signing & Capabilities* tab.)
3. Select your iPad or iPhone and press **Run**.

The entitlements in `Config/OMNIA.entitlements` — **Increased Memory Limit** and **Extended Virtual Addressing** — are standard capabilities. With automatic signing Xcode enables them on the App ID; no special approval is needed. They are essential: without them iOS limits OMNIA to a fraction of the device's memory.

**Simulator.** The app runs in the Simulator for UI work. llama.cpp falls back to the CPU there and memory limits are estimated, so use a real device to judge model performance.

**Tests.** `⌘U` runs the unit tests (GGUF parsing, memory planning, reasoning formats, Markdown, UTF-8 streaming, retrieval) on a simulator. The llama.cpp release XCFramework has no simulator slice, so first run `scripts/build-llama-xcframework.sh` once (needs CMake). It builds one from the same llama.cpp tag and places a combined copy in `Packages/LlamaFramework`, which `Package.swift` prefers while it exists. CI does the same and caches it.

## TestFlight

TestFlight distribution needs no App Store review for internal testers.

1. In [App Store Connect](https://appstoreconnect.apple.com) create an app with bundle ID `<prefix>.omnia` (platforms: iOS).
2. On your Mac, either
   - Xcode › **Product › Archive**, then **Distribute App › TestFlight Internal Only**, or
   - run `./scripts/archive.sh` (archives and uploads using `Config/ExportOptions.plist`).
3. After processing (usually 5–20 minutes), add yourself as an internal tester and install from the TestFlight app.

The build number increments automatically on upload (`manageAppVersionAndBuildNumber`). The binary contains **no models**: they download after installation.

### Without a Mac

Push the project to a private GitHub repository, add the secrets listed at the top of `.github/workflows/testflight.yml` (App Store Connect API key with Admin role, Team ID, bundle prefix), then run the **TestFlight** workflow from the Actions tab. The **Build** workflow compiles and tests every push.

## What's inside

```
OMNIA/
  App/            Entry point, composition root (AppServices), background download wake-ups
  Core/
    Engine/       llama.cpp runtime, generation, chat templates (Jinja), reasoning parsing, benchmark
    Memory/       Memory planner: budgets, per-architecture KV/compute estimates, context planning
    Device/       Device detection and optimization profiles (iPad quality / iPhone efficiency)
    GGUF/         GGUF header reader (local files and remote range requests)
    Models/       Catalog, recommendations, model store, background downloads, Files import
    Chat/         Conversations, comparison, export
    Documents/    Text extraction (text, code, Markdown, PDF, RTF) and on-device retrieval
    Persistence/  SwiftData schema and seed content
    Performance/  Measured CPU, memory, GPU allocation, thermal and power state
    Network/      Hugging Face client, connectivity
  UI/             SwiftUI: Home, Chat, Models, Compare, Library, Performance, Settings, Onboarding
OMNIATests/       Unit tests (Swift Testing)
Packages/         llama.cpp XCFramework package
Config/           Info.plist, entitlements, signing, export options
scripts/          Archive, icon rendering, catalog regeneration
```

**Engine.** Each loaded model lives on its own serial queue. Weights are memory-mapped and fully offloaded to Metal; flash attention and an F16/Q8_0/Q4_0 KV cache are chosen per load. Prompts reuse the KV cache for the longest common prefix, so follow-up turns only process new tokens. Streaming is UTF-8 safe, generation stops cleanly on Stop, background, memory pressure or critical temperature, and every number shown (tokens per second, time to first token, context use) is measured.

**Chat templates.** Newer models (Gemma 4, the Qwen3.5 family, gpt-oss, Granite 4.2, LFM3) need their exact Jinja templates. OMNIA renders the template stored in the GGUF with swift-jinja, as `llama-server --jinja` does, falling back to llama.cpp's built-in templates and then ChatML. Reasoning switches (`enable_thinking`, `reasoning_effort`, `reasoning_strength`) are exposed per conversation and per model, and reasoning is shown in a collapsible section for `<think>`, Gemma 4 thought channels, gpt-oss Harmony channels and Muse Glimmer messages.

## How models are chosen and loaded

OMNIA never rejects a model by parameter count. It reads the model's real file size and GGUF header, and estimates runtime memory per architecture:

- **Weights**: the file size (memory-mapped).
- **KV cache**: per layer, from KV heads × head size × context × cache precision. Sliding-window layers stop at their window (Gemma 4, gpt-oss, Muse Glimmer, LFM3); hybrid linear-attention layers hold a fixed state instead (Qwen3.5 family, LFM); shared-KV layers (Gemma 4 E-models) cost nothing.
- **Compute buffers** and runtime overhead.

That estimate must satisfy two limits measured at runtime:

1. **Resident memory**: a share of physical RAM, capped by Metal's recommended working set.
2. **App memory limit**: `os_proc_available_memory()` with the increased-limit entitlement. Developers report memory-mapped weights are not charged here; OMNIA still charges 10% of them as a margin.

After loading, OMNIA re-measures. If iOS reports too little headroom left, it unloads immediately instead of risking termination. Under memory warnings it releases idle models; on critical pressure it stops and releases everything. Loaded models are released after an idle period and when the app moves to the background (GPU work isn't permitted there), then reloaded on return.

**Profiles.** *iPad · Maximum quality*: 32K default context, F16 cache when it fits (Q8_0/Q4_0 before shortening context), larger batches. *iPhone · Efficiency*: 8K default context, Q8_0 cache, a tighter memory share, faster idle release and token pacing when the device runs hot. Both can be overridden in Settings.

**Recommendations.** For each mode — Maximum Quality, Balanced, Maximum Speed, Maximum Context — every catalog file is planned against the live limits, scored on curated quality minus a quantization penalty, and (for speed) on an estimated decode rate from memory bandwidth. Estimates are labelled as estimates; **Benchmark** on a model's page replaces them with measurements (512-token prompt, 128 generated tokens, three runs after a warm-up).

## Model catalog

`OMNIA/Core/Models/CatalogData.swift` lists 19 models (90 GGUF files) verified on 2026-11-02:

- Every repository is public (`gated: false`).
- Sizes and SHA-256 hashes come from the Hugging Face API, and every file answered a `HEAD` request without login.
- Architecture facts come from each file's actual GGUF header, read with HTTP range requests.

| Tier | Models |
|---|---|
| 20–35B (16 GB iPad, 2–3-bit) | Qwen3.8 27B · Ornith 1.5 35B-A3B · Qwen3.6 35B-A3B · Gemma 4 26B-A4B · gpt-oss-20b · Muse Glimmer 30B · LFM2.5 24B-A2B |
| 12–15B | Gemma 4 12B · Ministral 3 14B |
| 7–9B | Ornith 1.5 9B · MiMo-V2.6 Distill 9B · Qwen3.5 9B · Granite 4.2 8B |
| 1–4B | Qwen3.5 4B · Nemotron 3.5 Bolt E4B · Gemma 4 E4B · Granite 4.2 3B · LFM3 1.7B · Gemma 4 E2B |

Quality scores are curated from vendor-reported benchmarks. You can also search any public GGUF repository on Hugging Face from the Models tab — OMNIA reads the remote header to check the fit before you download — or import `.gguf` files from the Files app. Files copied to *On My iPad › OMNIA* import without a network.

Downloads use a background `URLSession` and can be paused, resumed (across relaunches) and retried. Each file is checked for size, SHA-256 and GGUF structure before it's used, and models are excluded from iCloud backup.

## Privacy

- Inference never uses the network. Conversations, documents and settings stay in the app's sandbox (SwiftData, no CloudKit).
- The only network traffic is model search and downloads from Hugging Face, which you initiate. **Offline-only mode** blocks even that.
- No accounts, no API keys, no analytics, no telemetry. `PrivacyInfo.xcprivacy` declares no data collection.

## Known limits

- **Not compiled here.** This project was written on Windows. Every llama.cpp call was checked against the pinned `include/llama.h`, and the swift-jinja calls against its source, but the first build happens on your Mac. Expect at most minor fix-ups.
- **MLX is not included yet.** It works on iPadOS and uses the M5's Neural Accelerators for prompt processing, but today it needs Xcode 26.4+, a separate safetensors download pipeline, and care around known issues (process aborts on background GPU errors, an open iOS 27 launch-hang report). The engine is behind an `InferenceBackend` protocol so MLX can be added as a second backend.
- **Core ML** is not used for text generation: on these devices Core ML LLMs are not faster than the Metal path and need per-model conversion.
- **No background generation.** iOS doesn't allow GPU work in the background. OMNIA stops cleanly and offers **Continue**. iPadOS 26's `BGContinuedProcessingTask` with GPU access (M3+ iPads, not iPhone) could allow it later.
- **Memory limits** for the M5 iPad Pro and iPhone 18 Pro with the increased-limit entitlement aren't published. OMNIA measures them at runtime; measure on a TestFlight build, since debug builds can differ.
- **GPU utilization and temperatures** aren't available through public iOS APIs; the Performance center says so instead of estimating.
- **Text only.** Several catalog models have vision encoders, but OMNIA loads the text model only and doesn't claim image or audio input.

## Maintenance

**Updating llama.cpp.** Pick a build from [llama.cpp releases](https://github.com/ggml-org/llama.cpp/releases). In `Packages/LlamaFramework/Package.swift`, replace `releaseURL` and `releaseChecksum`, the SHA-256 shown next to the `llama-bXXXXX-xcframework.zip` asset. Delete any local `Packages/LlamaFramework/llama.xcframework` and rerun `scripts/build-llama-xcframework.sh`; CI rebuilds its cached copy automatically. Diff `include/llama.h` against b11960 and adjust `Core/Engine/LlamaRuntime.swift` if the C API changed.

**Refreshing the catalog.** `scripts/catalog/models.json` holds the verified file list. Then run:
```
node scripts/read-gguf-headers.mjs scripts/catalog/models.json /tmp/omnia-headers
node scripts/generate-catalog.mjs scripts/catalog/models.json /tmp/omnia-headers/facts.json /tmp/omnia-headers OMNIA/Core/Models/CatalogData.swift
```

**App icon.** `py -3 scripts/make-icon.py OMNIA/Resources/Assets.xcassets/AppIcon.appiconset` re-renders the icon (three frosted glass discs meeting in one luminous center). The in-app mark (`UI/Design/OmniaMark.swift`) uses the same proportions.
