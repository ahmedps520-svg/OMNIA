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
    Documents/    Text extraction (text, code, Markdown, PDF, RTF), image preparation, on-device retrieval
    Tools/        Tools the model can call: calculator, date, documents, code, web
    Workspace/    WebKit sandbox for previews and running code, Pyodide runtime
    Voice/        On-device dictation (SpeechAnalyzer) and reading replies aloud
    Persistence/  SwiftData schema and seed content
    Performance/  Measured CPU, memory, GPU allocation, thermal and power state
    Network/      Hugging Face client, connectivity
  UI/             SwiftUI: Home, Chat, Models, Compare, Library, Performance, Settings, Onboarding
OMNIAWidgets/     WidgetKit extension: model download Live Activities
Shared/           Code compiled into the app and its extensions
OMNIATests/       Unit tests (Swift Testing)
Packages/         llama.cpp XCFramework package
Config/           Info.plist, entitlements, signing, export options
scripts/          Archive, icon rendering, catalog regeneration
```

**Engine.** Each loaded model lives on its own serial queue. Weights are memory-mapped and fully offloaded to Metal; flash attention and an F16/Q8_0/Q4_0 KV cache are chosen per load. Prompts reuse the KV cache for the longest common prefix, so follow-up turns only process new tokens. Streaming is UTF-8 safe, generation stops cleanly on Stop, background, memory pressure or critical temperature, and every number shown (tokens per second, time to first token, context use) is measured.

**MLX engine (beta).** A second engine runs MLX models with mlx-swift-lm 3.32.3 (mlx-swift 0.32.3, tokenizers from swift-transformers 1.4.0). MLX models are folders of safetensors from mlx-community, listed in the Models screen's MLX tab: Gemma 4 E2B, E4B and 12B, Qwen3.5 4B and 9B, and Granite 4.2 3B. Once downloaded, they're picked in a chat like any other model. They download file by file from a pinned commit, and each file is checked against its published SHA-256. On M5 chips (iPadOS 26.2 and later) MLX reads prompts with the GPU's Neural Accelerators. Prompts go through OMNIA's own chat-template renderer, so tools, reasoning switches and Continue behave as they do on llama.cpp.

**Photos and screenshots.** Vision models read images attached from Photos, Files or the clipboard. Their image encoder (an mmproj GGUF, verified by SHA-256 like the model) is an optional download per model, loaded with the first image through llama.cpp's multimodal library (`mtmd`). Images are stored once as upright sRGB JPEGs of at most 2048 pixels, without their metadata, and take up to 1,024 tokens each; an image already in the KV cache is recognised by its content and not read again. Models without image support are told an image was attached rather than shown nothing.

**Search by meaning.** The library can index documents with an optional embedding model (EmbeddingGemma 2, 310 MB, SHA-256 verified). Each passage's vector is stored with its document (half precision), and every question attached to a conversation's documents is ranked by both keywords (BM25) and meaning, merged by reciprocal rank fusion, so a passage that answers in other words or another language is found too. The model loads on demand, is released after 90 seconds idle, and pauses in the background; without it, search uses keywords as before.

**Workspace.** A panel beside each conversation (a sheet on iPhone) collects its code blocks. Web pages and SVG render with their console (an HTML page gets the CSS and scripts from the same reply), Markdown and JSON render natively, and JavaScript and Python run in a Web Worker inside WebKit's sandbox, with no network and a time limit. Python is Pyodide 314.0.7, an optional 13.5 MB download pinned by SHA-256 and served to WebKit offline. The panel also has a browser. The model gets the same sandbox as a `run_code` tool and, when a conversation allows web access (off by default, never in Offline-only mode), `web_search` (DuckDuckGo) and `open_url`, which read pages in a separate offscreen web view; every page it read can be opened in the browser.

**Voice.** The composer's microphone dictates with iOS 26's SpeechAnalyzer, entirely on device: SpeechTranscriber where the hardware supports it, DictationTranscriber otherwise, with the words appearing as they're recognized and the audio never stored. iOS downloads the speech model the first time a language is used. Replies can be read aloud, by tap or automatically, in the best installed voice for the reply's language (or the Spoken Content voice set in Accessibility); headings and lists get pauses, links are read by their text, web addresses by their site, and code blocks and equations are skipped. Reading continues with the screen locked.

**iPad.** A reply keeps generating when you switch apps (Settings › Memory & Performance). Every command is in the menu bar with a shortcut: ⌘N new chat, ⌥⌘N new window, ⌘K switch model, ⌘. stop, ⌘F search conversations, ⌘1–⌘7 sections, ⌘, settings. Any conversation opens in its own window from its context menu. Performance exports a device report (JSON): measured memory limit, model loads, benchmarks and median speeds, with no conversation content.

**Shortcuts and Lock Screen.** "Ask OMNIA" and "Summarize with OMNIA" (text, or a PDF, text or code file) work in Siri, Shortcuts and Spotlight and open the new chat. Model downloads show on the Lock Screen and in the Dynamic Island through a small WidgetKit extension.

**Chat templates.** Newer models (Gemma 4, the Qwen3.5 family, gpt-oss, Granite 4.2, LFM3) need their exact Jinja templates. OMNIA renders the template stored in the GGUF with swift-jinja, as `llama-server --jinja` does, falling back to llama.cpp's built-in templates and then ChatML. Reasoning switches (`enable_thinking`, `reasoning_effort`, `reasoning_strength`) are exposed per conversation and per model, and reasoning is shown in a collapsible section for `<think>`, Gemma 4 thought channels, gpt-oss Harmony channels and Muse Glimmer messages.

**Reasoning effort and reply length.** Settings › Inference sets how long reasoning models think: Light, Balanced (the default) or Thorough. Every template that takes a level gets it, so Qwen3.8 doesn't fall back to its own default, "xhigh", which second-guesses settled points at length. Templates that only switch thinking on or off (Qwen3.5 and 3.6, Ornith) get a token budget instead (`ReasoningBudget`): after 1,024 tokens of `<think>` on Light or 4,096 on Balanced (at most half the reply), OMNIA writes the sentence Qwen's own guide uses to cap thinking and closes the block, and the model answers. Thorough has no budget. Replies may run to 8,192 tokens, room to reason and then answer; the 2,048-token limit saved by builds 01–04 is raised once on update, and a limit chosen after that stays.

**Tool calls as they're written.** A call's markup is hidden from the reply, so a long one (code for `run_code`, say) used to look like a reply that had stopped. The tool and the call's latest lines now show while the model writes it, and a streaming reply shows its token count and speed (also in the iPad's background progress).

**Cluster.** A model too big for one device runs across several on the same Wi-Fi: up to 20 can join, and one model spreads over up to 16 of them (llama.cpp's limit). The device you chat on hosts (Cluster in the sidebar). Other iPhones and iPads join by scanning its QR code, with the Camera or in OMNIA. Devices OMNIA isn't tuned for, such as an iPhone 12 Pro Max or an iPad Air, open straight to lending. A Windows PC joins from a page the host serves: one PowerShell command starts OMNIA Node (`OMNIA/Resources/Cluster/omnia-node.ps1`). It downloads llama.cpp b11960's official `ggml-rpc-server` (CUDA for NVIDIA, Vulkan or CPU otherwise), verifies its SHA-256, and puts an access-controlled relay in front of it. Each new PC needs one tap of approval on the host. How it runs:
- **Engine.** It is llama.cpp's RPC backend, built into OMNIA's own build of llama.cpp (`scripts/build-llama-xcframework.sh`). Each device holds whole layers and its share of the KV cache. The host keeps the embeddings and the output layer, so the vocabulary-sized logits never cross the network. The host reads the workers' layers from the model file to send them; OMNIA's patch to llama.cpp then releases those pages, which upstream keeps in the host's memory for as long as the model is loaded. The host also keeps 512 MB of its budget free for that load.
- **Planning.** `ClusterPlanner` weighs each device's memory, its memory bandwidth (reported by Apple devices, looked up from the card's name for PCs) and its network round trip. It fills the fastest devices first and adds a device only when its memory is needed, since each one costs every token about a round trip and a half. **Every Device** spreads by memory instead.
- **When it's used.** Chats load a model on the cluster when it doesn't fit on the host alone, or, if chosen, whenever the cluster is clearly faster.
- **Lending.** Workers keep the screen on, and pause when OMNIA leaves the screen, since iOS gives apps no GPU in the background. When a worker drops out, the reply ends with an error naming it; the model reloads on the devices that are left. OMNIA's patch to llama.cpp (`scripts/llama/cluster.patch`) makes a lost connection fail the request instead of aborting the app, and time out instead of hanging. Weights a worker received are cached on it, so loading the same model again is fast.

**Default system prompt.** A conversation with no system prompt of its own (from the chat, a persona or the model's settings) gets OMNIA's: the device and date, to commit to an answer rather than second-guess it, to write each file in full in one tagged code block for the workspace (Swift as complete files for Xcode or Swift Playgrounds, since it can't run here), and the names of the tools the model can call.

## How models are chosen and loaded

OMNIA never rejects a model by parameter count. It reads the model's real file size and GGUF header, and estimates runtime memory per architecture:

- **Weights**: the file size (memory-mapped).
- **KV cache**: per layer, from KV heads × head size × context × cache precision. Sliding-window layers stop at their window (Gemma 4, gpt-oss, Muse Glimmer, LFM3); hybrid linear-attention layers hold a fixed state instead (Qwen3.5 family, LFM); shared-KV layers (Gemma 4 E-models) cost nothing.
- **Compute buffers** and runtime overhead.

That estimate must satisfy two limits measured at runtime:

1. **Resident memory**: a share of physical RAM, capped by Metal's recommended working set.
2. **App memory limit**: `os_proc_available_memory()` with the increased-limit entitlement. Developers report memory-mapped weights are not charged here; OMNIA still charges 10% of them as a margin.

After loading, OMNIA re-measures. If iOS reports too little headroom left, it unloads immediately instead of risking termination. Under memory warnings it releases idle models; on critical pressure it stops and releases everything. Loaded models are released after an idle period and when the app moves to the background (GPU work isn't permitted there), then reloaded on return.

**Beyond the limit.** A model that doesn't fit can still be used, at the user's risk. **Download Anyway** (on a catalog model's page, or after **Check Fit** on Hugging Face) asks first, and the model it installs has **Load beyond the memory limit** turned on; any installed model that doesn't fit offers the same switch on its page. Such a model loads alone with a 4K context and skips the headroom check, so replies are slow and iOS may close OMNIA if memory runs out.

**Profiles.** *iPad · Maximum quality*: 32K default context, F16 cache when it fits (Q8_0/Q4_0 before shortening context), larger batches. *iPhone · Efficiency*: 8K default context, Q8_0 cache, a tighter memory share, faster idle release and token pacing when the device runs hot. Both can be overridden in Settings.

**Recommendations.** For each mode — Maximum Quality, Balanced, Maximum Speed, Maximum Context — every catalog file is planned against the live limits, scored on curated quality minus a quantization penalty, and (for speed) on an estimated decode rate from memory bandwidth. Estimates are labelled as estimates; **Benchmark** on a model's page replaces them with measurements (512-token prompt, 128 generated tokens, three runs after a warm-up).

## Model catalog

`OMNIA/Core/Models/CatalogData.swift` lists 19 models (94 GGUF files) verified on 2026-11-02, and files for clusters verified on 2026-11-05: Qwen3.8 27B UD-Q4_K_M to Q8_0, Qwen3.6 35B-A3B UD-Q3_K_M to Q8_0 (16.6–36.9 GB), Ornith 1.5 35B-A3B IQ3_XXS to Q8_0 (15.3–37.8 GB), and a 20th model, Qwen3.5 122B-A10B (UD-IQ2_XXS 36.6 GB, UD-IQ2_M 39.1 GB, UD-Q2_K_XL 41.8 GB), which needs GPU PCs in the cluster. Unsloth's larger 122B quants come in several files, which OMNIA doesn't download yet. While a cluster is hosted, Models lists what it can run under **Runs on your cluster**.

- Every repository is public (`gated: false`).
- Sizes and SHA-256 hashes come from the Hugging Face API, and every file answered a `HEAD` request without login.
- Architecture facts come from each file's actual GGUF header, read with HTTP range requests.

| Tier | Models |
|---|---|
| 122B (clusters with GPU PCs) | Qwen3.5 122B-A10B |
| 20–35B (16 GB iPad, 2–3-bit) | Qwen3.8 27B · Ornith 1.5 35B-A3B · Qwen3.6 35B-A3B · Gemma 4 26B-A4B · gpt-oss-20b · Muse Glimmer 30B · LFM2.5 24B-A2B |
| 12–15B | Gemma 4 12B · Ministral 3 14B |
| 7–9B | Ornith 1.5 9B · MiMo-V2.6 Distill 9B · Qwen3.5 9B · Granite 4.2 8B |
| 1–4B | Qwen3.5 4B · Nemotron 3.5 Bolt E4B · Gemma 4 E4B · Granite 4.2 3B · LFM3 1.7B · Gemma 4 E2B |

15 of the models can see images: their image encoders (one per model, 120 MB–1.4 GB) were verified the same way on 2026-11-03 (Qwen3.5 122B-A10B's on 2026-11-05) and are offered on each installed model's page. Imported models can be given an encoder file from Files.

Quality scores are curated from vendor-reported benchmarks. You can also search any public GGUF repository on Hugging Face from the Models tab — OMNIA reads the remote header to check the fit before you download — or import `.gguf` files from the Files app. Files copied to *On My iPad › OMNIA* import without a network.

Downloads use a background `URLSession` and can be paused, resumed (across relaunches) and retried. Each file is checked for size, SHA-256 and GGUF structure before it's used, and models are excluded from iCloud backup.

## Privacy

- Inference never uses the network, unless you host a cluster. A cluster's model weights and activations then pass over your local network between your own devices, unencrypted. Nothing leaves the network, and no other device can join without the code on your screen or your approval. Conversations, documents and settings stay in the app's sandbox (SwiftData, no CloudKit).
- Dictation is recognized on device, and the microphone audio is neither stored nor sent anywhere.
- The only network traffic is model search and downloads from Hugging Face, which you initiate. **Offline-only mode** blocks even that.
- No accounts, no API keys, no analytics, no telemetry. `PrivacyInfo.xcprivacy` declares no data collection.

## Known limits

- **Not compiled here.** This project was written on Windows. Every llama.cpp call was checked against the pinned `include/llama.h`, and the swift-jinja calls against its source, but the first build happens on your Mac. Expect at most minor fix-ups.
- **MLX is a beta, text-only engine.** It has no image input, speculative decoding, JSON grammar or saved conversation memory, and it reads the whole conversation for every reply instead of reusing the cache. It can't run in the Simulator, so CI only builds it. An MLX error that iOS causes by taking the GPU away ends the app, so MLX replies stop when OMNIA starts leaving the screen, unless an iPad background task holds the GPU.
- **Core ML** is not used for text generation: on these devices Core ML LLMs are not faster than the Metal path and need per-model conversion.
- **Background generation is iPad-only.** On iPads with background GPU access (M3 and later) a reply keeps generating after you switch apps, as an iPadOS 26 continued processing task: iOS shows its progress with a button to stop it. iPhones get no GPU in the background, so OMNIA stops cleanly there and offers **Continue**.
- **Memory limits** for the M5 iPad Pro and iPhone 18 Pro with the increased-limit entitlement aren't published. OMNIA measures them at runtime; measure on a TestFlight build, since debug builds can differ.
- **GPU utilization and temperatures** aren't available through public iOS APIs; the Performance center says so instead of estimating.
- **Images, not audio or video.** Some image encoders (Gemma 4 E2B/E4B, Nemotron Bolt) also contain audio towers; OMNIA uses their vision part only.
- **Clusters trade speed for size.** Each token crosses the network once for each device holding layers. Wired PCs and a fast Wi-Fi router help; a crowded network slows every reply.
- **Weight transfer.** Loading sends each device its layers from the host, about a minute per 5 GB on good Wi-Fi; a reload reads them from the device's cache instead.
- **Supported models and PCs.** Clusters run GGUF models on llama.cpp only; MLX models stay on one device. OMNIA Node runs on Windows 10 and 11.
- **Same build everywhere.** llama.cpp's RPC protocol changes between builds, so every device must run the same one. The host refuses a mismatched device with an explanation.
- **PC upkeep.** OMNIA Node keeps the weights it received in `%LOCALAPPDATA%\OMNIA\Node\cache`, which grows with each model and isn't pruned; deleting the folder clears it. A new version of OMNIA Node is a new program to Windows, so its firewall question comes back once.

## Maintenance

**Updating llama.cpp.** Pick a build from [llama.cpp releases](https://github.com/ggml-org/llama.cpp/releases). Then:
1. In `Packages/LlamaFramework/Package.swift`, replace `releaseURL`, `releaseChecksum` and `releaseCommit`. The checksum is the SHA-256 shown next to the `llama-bXXXXX-xcframework.zip` asset; the commit is the one the tag points to.
2. Check that `scripts/llama/cluster.patch` still applies to that build, and update it if not.
3. In `ClusterProtocol` and `omnia-node.ps1`, update the build name, and in `omnia-node.ps1` the Windows assets and their SHA-256.
4. Delete any local `Packages/LlamaFramework/llama.xcframework` and rerun `scripts/build-llama-xcframework.sh`; CI rebuilds its cached copy automatically.
5. Diff `include/llama.h` against b11960 and adjust `Core/Engine/LlamaRuntime.swift` if the C API changed.

**Refreshing the catalog.** `scripts/catalog/models.json` holds the verified file list. Then run:
```
node scripts/read-gguf-headers.mjs scripts/catalog/models.json /tmp/omnia-headers
node scripts/generate-catalog.mjs scripts/catalog/models.json /tmp/omnia-headers/facts.json /tmp/omnia-headers OMNIA/Core/Models/CatalogData.swift
```

**App icon.** `py -3 scripts/make-icon.py OMNIA/Resources/Assets.xcassets/AppIcon.appiconset` re-renders the icon (three frosted glass discs meeting in one luminous center). The in-app mark (`UI/Design/OmniaMark.swift`) uses the same proportions.
