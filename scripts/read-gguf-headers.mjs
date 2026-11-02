// Reads GGUF metadata of catalog models via HTTP range requests (header only).
import fs from 'node:fs';
import path from 'node:path';

const [,, catalogPath, outDir] = process.argv;
const catalog = JSON.parse(fs.readFileSync(catalogPath, 'utf8'));

function parse(buf) {
  let o = 0;
  const need = (n) => { if (o + n > buf.length) throw { more: true }; };
  const u8 = () => { need(1); return buf.readUInt8(o++); };
  const u32 = () => { need(4); const v = buf.readUInt32LE(o); o += 4; return v; };
  const i32 = () => { need(4); const v = buf.readInt32LE(o); o += 4; return v; };
  const u64 = () => { need(8); const v = buf.readBigUInt64LE(o); o += 8; return Number(v); };
  const i64 = () => { need(8); const v = buf.readBigInt64LE(o); o += 8; return Number(v); };
  const f32 = () => { need(4); const v = buf.readFloatLE(o); o += 4; return v; };
  const f64 = () => { need(8); const v = buf.readDoubleLE(o); o += 8; return v; };
  const str = (keep = true) => { const n = u64(); need(n); const s = keep ? buf.toString('utf8', o, o + n) : null; o += n; return s; };
  const sizes = {0:1,1:1,2:2,3:2,4:4,5:4,6:4,7:1,10:8,11:8,12:8};
  const val = (t) => {
    switch (t) {
      case 0: return u8(); case 1: { need(1); return buf.readInt8(o++); }
      case 2: { need(2); const v = buf.readUInt16LE(o); o += 2; return v; }
      case 3: { need(2); const v = buf.readInt16LE(o); o += 2; return v; }
      case 4: return u32(); case 5: return i32(); case 6: return f32(); case 7: return u8() !== 0;
      case 8: return str(); case 10: return u64(); case 11: return i64(); case 12: return f64();
      case 9: {
        const et = u32(); const n = u64();
        if (et === 8) { for (let i = 0; i < n; i++) str(false); return { array: 'string', count: n }; }
        if (n <= 4096) { const a = []; for (let i = 0; i < n; i++) a.push(val(et)); return a; }
        need(n * sizes[et]); o += n * sizes[et]; return { array: et, count: n };
      }
      default: throw new Error('type ' + t);
    }
  };
  if (buf.toString('latin1', 0, 4) !== 'GGUF') throw new Error('not gguf');
  o = 4; const version = u32(); const nt = u64(); const nkv = u64();
  const md = {};
  for (let i = 0; i < nkv; i++) { const k = str(); const t = u32(); md[k] = val(t); }
  return { version, tensors: nt, md };
}

async function fetchRange(url, start, end) {
  const r = await fetch(url, { headers: { Range: `bytes=${start}-${end - 1}` } });
  if (r.status !== 206 && r.status !== 200) throw new Error('HTTP ' + r.status);
  return Buffer.from(await r.arrayBuffer());
}

async function inspect(repo, file) {
  const url = `https://huggingface.co/${repo}/resolve/main/${file}`;
  let buf = Buffer.alloc(0);
  for (const size of [4 << 20, 12 << 20, 32 << 20]) {
    if (buf.length < size) buf = Buffer.concat([buf, await fetchRange(url, buf.length, size)]);
    try { return parse(buf); } catch (e) { if (!e.more) throw e; }
  }
  throw new Error('header too large');
}

const results = [];
for (const m of catalog) {
  const smallest = [...m.files].sort((a, b) => a.size - b.size)[0];
  try {
    const { version, md } = await inspect(m.repo, smallest.filename);
    const a = md['general.architecture'];
    const g = (k) => md[`${a}.${k}`];
    const tmpl = md['tokenizer.chat_template'] || '';
    fs.writeFileSync(path.join(outDir, `${m.id}.jinja`), tmpl);
    const keys = Object.keys(md).filter(k => k.startsWith(a + '.'));
    results.push({
      id: m.id, file: smallest.filename, version, arch: a, name: md['general.name'],
      block_count: g('block_count'), context_length: g('context_length'), embedding_length: g('embedding_length'),
      head_count: g('attention.head_count'), head_count_kv: g('attention.head_count_kv'),
      key_length: g('attention.key_length'), value_length: g('attention.value_length'),
      sliding_window: g('attention.sliding_window'), swa_pattern: g('attention.sliding_window_pattern'),
      kv_lora_rank: g('attention.kv_lora_rank'), expert_count: g('expert_count'), expert_used: g('expert_used_count'),
      shared_kv_layers: g('attention.shared_kv_layers'), key_length_swa: g('attention.key_length_swa'), value_length_swa: g('attention.value_length_swa'), ssm_inner: g('ssm.inner_size'), ssm_state: g('ssm.state_size'), ssm_groups: g('ssm.group_count'), ssm_dt_rank: g('ssm.time_step_rank'), ssm_conv: g('ssm.conv_kernel'), nextn: g('nextn_predict_layers'), shortconv_cache: g('shortconv.l_cache'), ff: g('feed_forward_length'), expert_ff: g('expert_feed_forward_length'),
      recurrent_keys: keys.filter(k => /\.(ssm|shortconv|rwkv|wkv|linear_attn|full_attention_interval)/.test(k)),
      full_attention_interval: g('full_attention_interval'),
      vocab: md['tokenizer.ggml.tokens']?.count, file_type: md['general.file_type'],
      bos: md['tokenizer.ggml.bos_token_id'], eos: md['tokenizer.ggml.eos_token_id'], add_bos: md['tokenizer.ggml.add_bos_token'],
      template_len: tmpl.length, enable_thinking: tmpl.includes('enable_thinking'),
      all_arch_keys: keys
    });
    console.error('ok', m.id);
  } catch (e) {
    results.push({ id: m.id, error: String(e.message || e) });
    console.error('fail', m.id, e.message || e);
  }
}
fs.writeFileSync(path.join(outDir, 'facts.json'), JSON.stringify(results, null, 1));
