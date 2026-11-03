// Generates OMNIA's Swift model catalog from Hub-verified file data and GGUF header facts.
import fs from 'node:fs';
import path from 'node:path';

const [,, catalogPath, factsPath, headersDir, outPath] = process.argv;
const catalog = JSON.parse(fs.readFileSync(catalogPath, 'utf8'));
const facts = JSON.parse(fs.readFileSync(factsPath, 'utf8'));
const defaultPeriod = { gemma2: 2, gemma3: 6, gemma3n: 5, cohere2: 4, 'gpt-oss': 2, llama4: 4, exaone4: 4 };

// Curated presentation data. Quality score (0-100) reflects reasoning/chat quality from vendor-reported benchmarks.
const meta = {
  'qwen3.8-27b': { q: 92, released: 'August 2026', tags: ['Reasoning', 'Hybrid attention'],
    summary: "Qwen's strongest small model and the most capable in this catalog. Its hybrid Gated DeltaNet design keeps the KV cache tiny for long contexts; it thinks before answering by default." },
  'ornith-1.5-35b-a3b': { q: 89, released: 'August 2026', tags: ['Reasoning', 'Mixture of experts'],
    summary: 'Qwen3.6-architecture mixture of experts refined with reinforcement learning. Very strong reasoning and coding scores with only about 3B parameters active per token.' },
  'qwen3.6-35b-a3b': { q: 87, released: 'April 2026', tags: ['Reasoning', 'Mixture of experts'],
    summary: '256-expert mixture of experts with about 3B active parameters: high reasoning quality at the speed of a small model.' },
  'gemma-4-26b-a4b-it': { q: 85, released: 'April 2026', tags: ['Mixture of experts', 'Optional reasoning'],
    summary: "Google DeepMind's Gemma 4 mixture of experts (3.8B active). Excellent writing and multilingual quality; reasoning can be switched on." },
  'gpt-oss-20b': { q: 82, released: 'August 2025', tags: ['Reasoning', 'Mixture of experts'],
    summary: "OpenAI's open-weight reasoning model in its native MXFP4 precision. It reasons in a separate analysis channel before answering." },
  'muse-glimmer-30b': { q: 82, released: 'August 2026', tags: ['Reasoning', 'Dense'],
    summary: "Meta's 2026 open-weight model, distilled from Muse Spark, with adjustable reasoning strength. Dense, so slower than mixture-of-experts peers." },
  'ornith-1.5-9b': { q: 81, released: 'August 2026', tags: ['Reasoning', 'Hybrid attention'],
    summary: 'The strongest model around 9B on published benchmarks: Qwen3.5-9B further trained with a self-improving reinforcement learning loop.' },
  'gemma-4-12b-it': { q: 80, released: 'May 2026', tags: ['Optional reasoning', 'Dense'],
    summary: 'Dense Gemma 4 with long context and polished, well-formatted answers. Reasoning is off by default and can be enabled per conversation.' },
  'mimo-v2.6-distill-qwen-9b': { q: 79, released: 'September 2026', tags: ['Reasoning', 'Coding'],
    summary: "Xiaomi's distillation of MiMo-V2.6 into Qwen3.5-9B, with large gains on coding and agentic benchmarks." },
  'qwen3.5-9b': { q: 77, released: 'February 2026', tags: ['Reasoning', 'Hybrid attention'],
    summary: 'Well-rounded 9B hybrid model with a 262K context window and a very small KV cache.' },
  'ministral-3-14b-instruct-2512': { q: 76, released: 'December 2025', tags: ['Fast answers', 'Dense'],
    summary: "Mistral's 14B instruct model answers directly without a thinking phase, so replies start quickly. Mistral recommends a low temperature." },
  'lfm2.5-24b-a2b': { q: 74, released: 'October 2026', tags: ['Reasoning', 'Mixture of experts', 'Fast'],
    summary: 'Liquid AI hybrid mixture of experts with only 2.45B active parameters: the fastest 20B-class model, built for on-device agents.' },
  'granite-4.2-8b': { q: 72, released: 'August 2026', tags: ['Reasoning', 'Dense'],
    summary: "IBM's 8B reasoning model with strong math and tool-use results and a low-effort reasoning mode." },
  'qwen3.5-4b': { q: 70, released: 'February 2026', tags: ['Reasoning', 'Efficient'],
    summary: 'The best general-knowledge and reasoning model around 4B parameters. An excellent everyday choice on iPhone.' },
  'nemotron-3.5-bolt-e4b': { q: 66, released: 'October 2026', tags: ['Conversation', 'Efficient'],
    summary: "NVIDIA's chat-tuned Gemma 4 E4B, focused on natural conversation and instruction following." },
  'gemma-4-e4b-it': { q: 64, released: 'April 2026', tags: ['Efficient', 'Optional reasoning'],
    summary: 'Gemma 4 with 4.5B effective parameters, designed for phones and tablets.' },
  'granite-4.2-3b': { q: 60, released: 'August 2026', tags: ['Reasoning', 'Efficient'],
    summary: 'Compact IBM reasoning model that tops independent rankings for models under 4B.' },
  'lfm3-1.7b': { q: 55, released: 'October 2026', tags: ['Fastest', 'Reasoning'],
    summary: 'Liquid AI tri-hybrid model under 2 GB with a 262K context. Extremely fast; best for quick tasks and drafts.' },
  'gemma-4-e2b-it': { q: 54, released: 'April 2026', tags: ['Fastest', 'Efficient'],
    summary: 'The smallest Gemma 4 (2.3B effective parameters) for the quickest responses.' },
};
const licenseNames = { 'apache-2.0': 'Apache 2.0', mit: 'MIT', 'lfm1.0': 'LFM Open License 1.0', 'openmdw-1.1': 'OpenMDW 1.1' };

function computeFacts(x, model) {
  const L = x.block_count;
  const headCount = Array.isArray(x.head_count) ? Math.max(...x.head_count) : x.head_count;
  const perLayer = Array.isArray(x.head_count_kv) ? x.head_count_kv : Array(L).fill(x.head_count_kv ?? headCount);
  const headDim = x.key_length ?? Math.floor(x.embedding_length / headCount);
  const k = x.key_length ?? headDim;
  const v = x.value_length ?? k;
  const kswa = x.key_length_swa ?? k;
  const vswa = x.value_length_swa ?? v;
  const limit = L - Math.min(L, x.shared_kv_layers ?? 0);
  let swa = null;
  if (Array.isArray(x.swa_pattern) && x.swa_pattern.length === L) swa = x.swa_pattern.map(Boolean);
  else if (typeof x.swa_pattern === 'number' && x.swa_pattern > 1) swa = [...Array(L)].map((_, i) => (i + 1) % x.swa_pattern !== 0);
  else if (x.sliding_window && defaultPeriod[x.arch]) swa = [...Array(L)].map((_, i) => (i + 1) % defaultPeriod[x.arch] !== 0);
  let full = 0;
  let sliding = 0;
  let rec = 0;
  for (let i = 0; i < L; i++) {
    const heads = i < perLayer.length ? perLayer[i] : perLayer[perLayer.length - 1];
    const isRec = x.full_attention_interval > 0 ? (i + 1) % x.full_attention_interval !== 0 : heads === 0;
    if (isRec) { rec++; continue; }
    if (i >= limit) continue;
    if (x.sliding_window && swa && swa[i]) sliding += heads * (kswa + vswa);
    else full += heads * (k + v);
  }
  let statePerLayer = 0;
  if (x.ssm_inner && x.ssm_state) {
    statePerLayer = x.ssm_inner * x.ssm_state * 4 + (Math.max(1, x.ssm_conv ?? 4) - 1) * (x.ssm_inner + 2 * (x.ssm_groups ?? 1) * x.ssm_state) * 4;
  } else if (x.shortconv_cache) {
    statePerLayer = x.shortconv_cache * x.embedding_length * 4;
  } else if (x.recurrent_keys && x.recurrent_keys.length) {
    statePerLayer = 4 << 20;
  }
  const template = fs.readFileSync(path.join(headersDir, `${model.id}.jinja`), 'utf8');
  const thinking = /enable_thinking|reasoning_effort|reasoning_strength/.test(template);
  return { arch: x.arch, L, full, sliding, window: x.sliding_window ?? 0, lora: x.kv_lora_rank ?? 0,
           state: statePerLayer * rec, embd: x.embedding_length, vocab: x.vocab, ctx: x.context_length, thinking };
}

const str = (s) => JSON.stringify(s);
const num = (n) => n.toString().replace(/\B(?=(\d{3})+(?!\d))/g, '_');
const lines = [];
lines.push('// Generated from Hugging Face API data (sizes, SHA-256) and each file\'s GGUF header (architecture facts).');
lines.push('// Every repository below was verified as openly downloadable (not gated) on 2026-11-02.');
lines.push('// Image encoders (mmproj files, for photos and screenshots) were verified the same way on 2026-11-03.');
lines.push('// Regenerate with scripts/generate-catalog.mjs rather than editing by hand.');
lines.push('');
lines.push('import Foundation');
lines.push('');
lines.push('extension ModelCatalog {');
lines.push('    static let curated: [CatalogModel] = [');
const entries = [];
for (const m of catalog) {
  const x = facts.find((f) => f.id === m.id);
  const info = meta[m.id];
  if (!x || x.error || !info) throw new Error('missing data for ' + m.id);
  const f = computeFacts(x, m);
  const variants = m.files.map((v) =>
    `                CatalogVariant(quant: ${str(v.quant)}, fileName: ${str(v.filename)}, sizeBytes: ${num(v.size)}, sha256: ${str(v.sha256)})`
  ).join(',\n');
  entries.push([
    '        CatalogModel(',
    `            id: ${str(m.id)},`,
    `            name: ${str(m.name)},`,
    `            developer: ${str(m.developer)},`,
    `            repo: ${str(m.repo)},`,
    `            license: ${str(licenseNames[m.license] ?? m.license)},`,
    `            released: ${str(info.released)},`,
    `            summary: ${str(info.summary)},`,
    `            qualityScore: ${info.q},`,
    `            tags: [${info.tags.map(str).join(', ')}],`,
    '            facts: ArchitectureFacts(',
    `                architecture: ${str(f.arch)}, layers: ${f.L}, kvElementsFull: ${num(f.full)}, kvElementsSliding: ${num(f.sliding)},`,
    `                slidingWindow: ${num(f.window)}, kvLoraRank: ${f.lora}, recurrentStateBytes: ${num(f.state)},`,
    `                embeddingLength: ${num(f.embd)}, vocabSize: ${num(f.vocab)}, trainContext: ${num(f.ctx)},`,
    `                parameters: ${m.params_total_b}, activeParameters: ${m.params_active_b}, thinkingToggle: ${f.thinking}),`,
    '            variants: [',
    variants,
    m.projector ? '            ],' : '            ]',
    ...(m.projector ? [
      `            projector: CatalogProjector(repo: ${str(m.projector.repo)}, fileName: ${str(m.projector.filename)},`,
      `                                        sizeBytes: ${num(m.projector.size)}, sha256: ${str(m.projector.sha256)})`
    ] : []),
    '        )'
  ].join('\n'));
}
lines.push(entries.join(',\n'));
lines.push('    ]');
lines.push('}');
lines.push('');
fs.writeFileSync(outPath, lines.join('\n'));
console.log('wrote', outPath, catalog.length, 'models');
