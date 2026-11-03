// Generates OMNIA's MLX catalog (Swift) from scripts/catalog/mlx-models.json: Hub-verified files at
// pinned commits, with architecture facts computed from each config.json the same way the app's
// MLXModelInspector reads an installed folder.
// Usage: node scripts/generate-mlx-catalog.mjs scripts/catalog/mlx-models.json OMNIA/Core/Models/MLXCatalogData.swift
import fs from 'node:fs';

const [,, inPath, outPath] = process.argv;
const { models } = JSON.parse(fs.readFileSync(inPath, 'utf8'));
const licenseNames = { 'apache-2.0': 'Apache 2.0', mit: 'MIT' };
const str = (s) => JSON.stringify(s);
const num = (n) => n.toString().replace(/\B(?=(\d{3})+(?!\d))/g, '_');

/** Mirrors MLXModelInspector.info(config:weightBytes:chatTemplate:). */
function facts(config, weightBytes) {
  const layers = config.num_hidden_layers;
  const heads = config.num_attention_heads ?? 1;
  const kvHeads = config.num_key_value_heads ?? heads;
  const hidden = config.hidden_size ?? 0;
  const headDim = config.head_dim ?? (heads > 0 ? Math.floor(hidden / heads) : 0);
  const fullHeads = config.num_global_key_value_heads ?? kvHeads;
  const fullHeadDim = config.global_head_dim ?? headDim;
  const window = config.sliding_window ?? 0;
  const cachedLayers = Math.max(layers - (config.num_kv_shared_layers ?? 0), 0);
  const isLinear = (t) => t.includes('linear') || t.includes('mamba') || t.includes('conv');
  let full = cachedLayers, sliding = 0, linear = 0;
  if (Array.isArray(config.layer_types) && config.layer_types.length === layers) {
    const cached = config.layer_types.slice(0, cachedLayers);
    sliding = cached.filter((t) => t.includes('sliding')).length;
    full = cached.filter((t) => !t.includes('sliding') && !isLinear(t)).length;
    linear = config.layer_types.filter(isLinear).length;
  } else if ((config.sliding_window_pattern ?? 0) > 1 && window > 0) {
    full = Math.floor(cachedLayers / config.sliding_window_pattern);
    sliding = cachedLayers - full;
  }
  let recurrent = 0;
  if (linear > 0) {
    const vh = config.linear_num_value_heads ?? 0, kd = config.linear_key_head_dim ?? 0, vd = config.linear_value_head_dim ?? 0;
    const kh = config.linear_num_key_heads ?? 0, kernel = Math.max(config.linear_conv_kernel_dim ?? 0, 1);
    const perLayer = vh > 0 && kd > 0 && vd > 0 ? vh * kd * vd * 4 + (kh * kd * 2 + vh * vd) * (kernel - 1) * 2 : 16 * 2 ** 20;
    recurrent = linear * perLayer;
  }
  return {
    full: full * fullHeads * fullHeadDim * 2, sliding: sliding * kvHeads * headDim * 2,
    window: sliding > 0 ? window : 0, state: recurrent, embd: hidden, vocab: config.vocab_size ?? 0,
    ctx: config.max_position_embeddings ?? 4096, weightBytes
  };
}

const lines = [
  "// MLX models: folders of safetensors run by the MLX engine, from public Hugging Face repositories.",
  "// Generated from scripts/catalog/mlx-models.json (Hub file sizes and SHA-256 at pinned commits, and",
  "// each config.json). Regenerate with scripts/generate-mlx-catalog.mjs rather than editing by hand.",
  '',
  'import Foundation',
  '',
  'extension ModelCatalog {',
  '    static let mlx: [CatalogModel] = ['
];
const entries = models.map((m) => {
  const weights = m.files.filter((f) => f.path.endsWith('.safetensors')).reduce((t, f) => t + f.size, 0);
  const total = m.files.reduce((t, f) => t + f.size, 0);
  const f = facts(m.config, weights);
  const files = m.files.map((file) =>
    `                    ModelFile(path: ${str(file.path)}, bytes: ${num(file.size)}, sha256: ${str(file.sha256)})`).join(',\n');
  const folder = m.repo.split('/')[1];
  return [
    '        CatalogModel(',
    `            id: ${str(m.id)},`,
    `            name: ${str(m.name)},`,
    `            developer: ${str(m.developer)},`,
    `            repo: ${str(m.repo)},`,
    `            license: ${str(licenseNames[m.license] ?? m.license)},`,
    `            released: ${str(m.released)},`,
    `            summary: ${str(m.summary)},`,
    `            qualityScore: ${m.q},`,
    `            tags: [${m.tags.map(str).join(', ')}],`,
    '            facts: ArchitectureFacts(',
    `                architecture: ${str(m.config.model_type)}, layers: ${m.config.num_hidden_layers}, kvElementsFull: ${num(f.full)}, kvElementsSliding: ${num(f.sliding)},`,
    `                slidingWindow: ${num(f.window)}, recurrentStateBytes: ${num(f.state)},`,
    `                embeddingLength: ${num(f.embd)}, vocabSize: ${num(f.vocab)}, trainContext: ${num(f.ctx)},`,
    `                parameters: ${m.params_total_b}, activeParameters: ${m.params_active_b}, thinkingToggle: ${m.thinking}),`,
    '            variants: [',
    `                CatalogVariant(quant: ${str(m.quant)}, fileName: ${str(folder)}, sizeBytes: ${num(total)}, sha256: "", files: [`,
    files,
    `                ], revision: ${str(m.revision)})`,
    '            ]',
    '        )'
  ].join('\n');
});
lines.push(entries.join(',\n'));
lines.push('    ]');
lines.push('}');
lines.push('');
fs.writeFileSync(outPath, lines.join('\n'));
console.log('wrote', outPath, models.length, 'MLX models');
