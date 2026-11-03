#!/usr/bin/env bash
#
# Downloads the small public GGUF models used by the engine tests (OMNIATests/Engine*.swift)
# into the given directory and verifies each file's SHA-256. Verified files are kept, so a
# rerun only fetches what's missing. CI caches the directory and passes it to the tests as
# OMNIA_TEST_MODELS; without it the engine suites are skipped.
#
#   stories260K, stories15M  llama2.c TinyStories models (MIT), from llama.cpp's own test set
#   bge-small                BAAI bge-small-en-v1.5 embedding model (MIT)
#   SmolVLM-256M             HuggingFaceTB SmolVLM 256M Instruct + image encoder (Apache-2.0)
#   Qwen3.5-0.8B (two)       Qwen3.5 0.8B, a hybrid (linear + full attention) model (Apache-2.0),
#                            quantized by unsloth and by bartowski: a speculative-decoding pair;
#                            bartowski's image encoder makes it the M-RoPE vision test model
#
# Usage: scripts/fetch-test-models.sh <directory>
set -euo pipefail

dir="${1:?usage: fetch-test-models.sh <directory>}"
mkdir -p "$dir"

hf="https://huggingface.co"
# file name, SHA-256, URL
models=(
  "stories260K.gguf 270cba1bd5109f42d03350f60406024560464db173c0e387d91f0426d3bd256d $hf/ggml-org/models-moved/resolve/main/tinyllamas/stories260K.gguf"
  "stories15M-q4_0.gguf 66967fbece6dbe97886593fdbb73589584927e29119ec31f08090732d1861739 $hf/ggml-org/models-moved/resolve/main/tinyllamas/stories15M-q4_0.gguf"
  "stories15M-q8_0.gguf 2eda49203f2f044f3dddf29a7dd7cc861ef5a0340f518a19613d73ba6d9c06b6 $hf/ggml-org/models-moved/resolve/main/tinyllamas/stories15M-q8_0.gguf"
  "bge-small-f16.gguf f0b2fef971e8366438bfd2d9aefea1b0115919389448806d290237f638bae999 $hf/ggml-org/models-moved/resolve/main/bert-bge-small/ggml-model-f16.gguf"
  "SmolVLM-256M-Instruct-Q8_0.gguf 2a31195d3769c0b0fd0a4906201666108834848db768af11de1d2cef7cd35e65 $hf/ggml-org/SmolVLM-256M-Instruct-GGUF/resolve/main/SmolVLM-256M-Instruct-Q8_0.gguf"
  "mmproj-SmolVLM-256M-Instruct-Q8_0.gguf 7e943f7c53f0382a6fc41b6ee0c2def63ba4fded9ab8ed039cc9e2ab905e0edd $hf/ggml-org/SmolVLM-256M-Instruct-GGUF/resolve/main/mmproj-SmolVLM-256M-Instruct-Q8_0.gguf"
  "Qwen3.5-0.8B-Q4_0.gguf 444406ddd926550c724ec18d5120a9d40ded44908a063b0e66e9a7e5464c652c $hf/unsloth/Qwen3.5-0.8B-GGUF/resolve/main/Qwen3.5-0.8B-Q4_0.gguf"
  "Qwen_Qwen3.5-0.8B-Q4_0.gguf 407c9dec5a813ebe4ed381e26b9b04f62b9041ea96f1a054ff9aa67c2fe46b36 $hf/bartowski/Qwen_Qwen3.5-0.8B-GGUF/resolve/main/Qwen_Qwen3.5-0.8B-Q4_0.gguf"
  "mmproj-Qwen_Qwen3.5-0.8B-f16.gguf 1dc1351c82e41b48edb55fd6ddfa7ca60fb5a16b3d5abf3ce7054880dd022847 $hf/bartowski/Qwen_Qwen3.5-0.8B-GGUF/resolve/main/mmproj-Qwen_Qwen3.5-0.8B-f16.gguf"
)

for entry in "${models[@]}"; do
  read -r name sha url <<<"$entry"
  path="$dir/$name"
  if [ -f "$path" ] && echo "$sha  $path" | shasum -a 256 -c - >/dev/null 2>&1; then
    echo "verified  $name"
    continue
  fi
  echo "fetching  $name"
  curl -fsSL --retry 3 -o "$path.part" "$url"
  echo "$sha  $path.part" | shasum -a 256 -c - >/dev/null
  mv "$path.part" "$path"
done
