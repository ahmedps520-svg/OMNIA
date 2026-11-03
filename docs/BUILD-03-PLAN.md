# OMNIA build 03 plan

Build 03 adds everything from the build-03 ideas list, plus a **workspace panel** for previewing and running code and a **browser** the AI can use. Each feature is designed, implemented, tested and compiled on its own before the next one starts. Nothing goes to TestFlight until the whole build is green.

Status: **in progress**. This file is updated as stages land.

---

## How every feature is verified

OMNIA is developed without a local Mac, so each check has to run in the cloud:

| Check | What it proves | Where |
|---|---|---|
| Unit tests | Parsers, planners, prompt building, tool logic and so on behave as designed | GitHub Actions, iPad simulator |
| Engine tests with tiny models | llama.cpp features really run end to end, including saved memory, JSON, tools, speculative decoding, embeddings and images. Small public GGUF models (a few MB to ~200 MB) are downloaded and cached on CI. | GitHub Actions, iPad simulator (CPU) |
| Device compile | The Release app builds for real iPads and iPhones | GitHub Actions |
| Signing check | New capabilities and extensions sign correctly | TestFlight workflow, before the final upload |
| Your devices | Things a cloud Mac can't do: GPU speed, Apple Intelligence, microphone, background GPU, Lock Screen, share sheet | A short checklist when build 03 arrives |

---

## Stage 1: Test foundation (done)

- llama.cpp's release framework has no simulator slice, so CI now builds one from the same source tag and caches it. Release builds still use the official, checksum-verified framework.
- New engine-test harness: real model loads and generations on the simulator's CPU with tiny models.

## Stage 2: Saved chat memory, JSON mode and tools (done)

**Saved chat memory.** After a long reply, OMNIA saves the model's working memory (its KV cache) for that conversation. Reopening the chat later continues instantly instead of re-reading the whole history.
- The save is tied to the exact model and settings, and is discarded if either changes.
- Storage is capped and the least-recently-used saves go first. Deleting a conversation deletes its save. Settings has an on/off switch and a "Clear" button.

**JSON mode.** A per-conversation setting that forces valid JSON output using llama.cpp's grammar-constrained sampling. Thinking is switched off in this mode, because constrained output can't contain a reasoning block.

**Tools.** The model can call tools mid-answer, and each call shows in the chat as a collapsible step:
- Calculator
- Date and time
- Search your documents
- Web search and open web page (stage 6, only when web access is on)
- Run code (stage 6)

Tool calls use each model's own chat-template format (Qwen/Hermes, Gemma, gpt-oss, Mistral, Granite, LFM). Models without native tool support get a described protocol instead. Each conversation can turn tools on or off.

## Stage 3: Speculative decoding (implemented)

A small "draft" model guesses several tokens ahead and the big model checks them all at once. That makes big models answer faster with identical output quality, because every emitted token is still the big model's own choice.
- OMNIA offers this only when both models share a tokenizer.
- The memory planner counts both models.
- Hybrid models (the Qwen3.5 family) undo rejected guesses from llama.cpp's recurrent-state snapshots, which the memory planner also counts.

## Stage 4: Photos and screenshots in chat (implemented)

- Attach photos, screenshots or images from Files or the clipboard (up to 4 per message).
- 14 catalog models get their image encoders (mmproj files, SHA-256 verified); each installed model's page offers them as a one-tap download. Imported models can take an encoder file from Files.
- Uses llama.cpp's multimodal library (`mtmd`) from the pinned framework. An image already in the model's memory is recognised by content and not read again; M-RoPE models (the Qwen3.5 family) are handled.
- Memory planning keeps room for the encoder, which loads with the first image.
- Tests: image preparation, prompt placement, encoder storage, chat, and real image runs with SmolVLM and Qwen3.5 0.8B on CI.

## Stage 5: Smarter document search (implemented)

- An optional small embedding model (EmbeddingGemma 2, 310 MB, downloaded from the Library) finds passages by meaning, combined with the existing keyword search by reciprocal rank fusion.
- Documents are indexed once, on device, in the background; new documents are indexed as they're added. Vectors are stored with each document in half precision.
- Used for the excerpts placed in the prompt and by the search-documents tool. Without the model, or when it can't run (background, low memory), search falls back to keywords.
- Tests: fusion ranking, vector storage, and real embeddings and indexing with BGE small on CI.

## Stage 6: Workspace panel, browser and web access (implemented)

A panel beside the chat on iPad (a sheet on iPhone), with three tabs:

- **Preview** shows the selected block: HTML with the CSS and JavaScript from the same reply, SVG, Markdown and JSON, with a console for logs and errors. **Run** works for JavaScript and **Python**. Programs run in a Web Worker in WebKit's sandbox, with no network and a time limit. Python is Pyodide 314.0.7, an optional 13.5 MB download (SHA-256 pinned) that then works offline. Previews of pages may load web resources, except in Offline-only mode.
- **Code** lists every code block in the conversation. Copy, share or save to Files, or open any of them in Preview. Code blocks in the chat have Preview and Run buttons too.
- **Browser** is an in-app browser with an address bar, back/forward, reload and share. "Ask about this page" attaches the page's text to your message.

**AI web access** is off by default (Settings › Workspace, and per conversation) and blocked by Offline-only mode. When it's on, the model can search the web (DuckDuckGo) and open pages, read in a separate offscreen web view. Every page or search it used can be opened in the Browser tab from its step in the reply.

The model can also run the code it writes (`run_code`) and read back the output or errors, so it can fix its own mistakes.

Tests: code extraction and previews, web helpers, JavaScript runs (output, errors, top-level await, runaway programs), and Python end to end with Pyodide on CI.

## Stage 7: More engines

**Apple's on-device model.** Appears as a built-in model with no download needed. It needs Apple Intelligence to be on, and works in chat and Compare. Its context window is small (about 4,000 tokens) and OMNIA says so. Only statistics Apple's API actually provides are shown.

**MLX engine.** An optional second engine for MLX-format models (safetensors from mlx-community). It uses the M5's Neural Accelerators for faster prompt reading. MLX models get their own catalog section, memory estimates and download handling.

## Stage 8: Voice

- **Dictation:** a microphone button in the composer, with live on-device transcription.
- **Read aloud:** reads a reply aloud, with optional automatic reading. Markdown and code are cleaned up for speech.

## Stage 9: iPad power features

- **Background answers (iPad):** an answer keeps generating after you switch apps. This uses iPadOS 26's continued processing with background GPU access, with progress shown by the system. iPhone keeps the current behavior: it pauses and offers Continue.
- **Keyboard shortcuts:**
  - ⌘N new chat
  - ⌘K switch model
  - ⌘. stop
  - ⌘F search
  - ⌘1–5 sections
  - ⌘, settings
- **Multiple windows:** open any chat in its own window (Stage Manager, Split View).
- **Device report:** a one-tap export of measured memory limits, load results and speeds, with no conversation content. Used to tune model fitting for your exact devices.

## Stage 10: Share sheet, Shortcuts, Lock Screen

- **Share extension:** "OMNIA" appears in the share sheet for text, links, images and PDFs, with an optional question. The item opens in a new chat the next time you open OMNIA. Apple doesn't let share extensions launch their app.
- **Shortcuts and Siri:** "Ask OMNIA" and "Summarize with OMNIA" actions, which can also appear in the share sheet.
- **Live Activity:** model download progress on the Lock Screen and in the Dynamic Island.

## Stage 11: Release

All tests green → TestFlight workflow → build 03 → your device checklist.

---

## Privacy (unchanged principles)

- Inference stays on device: llama.cpp, MLX, or Apple's on-device model.
- The only network use is what you turn on: model downloads, web access for the AI, network in previews, and pages you open in the browser. Offline-only mode blocks all of it.
- No accounts, analytics or telemetry. The device report is shared only when you choose to.

## Known risks

- **New capabilities** (App Groups for the share extension, background GPU) may need switching on in the Apple developer portal. The signing check catches this before release.
- **MLX on the simulator** is limited, so MLX is verified by compiling and by your device checklist rather than by CI engine tests.
- **Large build:** if one stage hits a hard platform limit, it's documented here and the rest still ships.
