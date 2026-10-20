#!/usr/bin/env node
// /usr/bin/ffmpeg 대체 shim — G.711(μ-law/A-law) 변환 전용 (README §2 "ffmpeg 선택")
//
// IVR 시나리오 노드(ivr-server.js /API/UPLOAD)와 nxwav2g711 이 호출하는 형태만 지원한다:
//   ffmpeg [-v N] [-y] -i <in.wav> [-ar 8000 -ac 1 -ab 64k [-strict -2] [-threads N]] -f mulaw|alaw <out> [... 반복]
// 입력: RIFF/WAVE PCM 8/16/24/32bit · float32, 모노/스테레오, 임의 샘플레이트 → 8kHz 모노 G.711.
// MP3 등 압축 포맷은 실패(exit 1)로 끝난다 — 필요하면 WITH_FFMPEG=1 로 빌드한 이미지를 쓴다.
// 실제 파일을 /usr/bin/ffmpeg 에 두는 이유: ivr-server.js 는 ffmpeg 부재 시 spawn 'error' 를 처리하지 않아 Node-RED 가 죽는다.
'use strict';
const fs = require('fs');

function fail(msg) { console.error('ffmpeg(g711-shim): ' + msg); process.exit(1); }

const VALUE_OPTS = new Set(['-v', '-loglevel', '-ar', '-ac', '-ab', '-b:a', '-f', '-threads', '-strict', '-i', '-acodec', '-c:a']);
const argv = process.argv.slice(2);
if (argv.includes('-version')) { console.log('ffmpeg version g711-shim (aicc-ivr-nodered) — WAV PCM → G.711 only'); process.exit(0); }
let input = null, cur = {}; const outputs = [];
for (let i = 0; i < argv.length; i++) {
  const a = argv[i];
  if (a === '-y' || a === '-hide_banner' || a === '-nostdin') continue;
  if (VALUE_OPTS.has(a)) { const v = argv[++i]; if (a === '-i') input = v; else cur[a] = v; continue; }
  if (a.startsWith('-')) continue;                       // 알 수 없는 단독 플래그 무시
  outputs.push({ file: a, fmt: cur['-f'], rate: Number(cur['-ar'] || 8000) }); cur = {};
}
if (!input || !outputs.length) fail('usage: -i <in.wav> -f mulaw|alaw <out>');

// ── WAV 파싱 ──
const buf = fs.readFileSync(input);
if (buf.toString('ascii', 0, 4) !== 'RIFF' || buf.toString('ascii', 8, 12) !== 'WAVE')
  fail(`${input}: WAV(RIFF) 아님 — MP3 등은 WITH_FFMPEG=1 이미지 필요`);
let off = 12, fmt = null, data = null;
while (off + 8 <= buf.length) {
  const id = buf.toString('ascii', off, off + 4), size = buf.readUInt32LE(off + 4), body = off + 8;
  if (id === 'fmt ') fmt = { tag: buf.readUInt16LE(body), ch: buf.readUInt16LE(body + 2), rate: buf.readUInt32LE(body + 4), bits: buf.readUInt16LE(body + 14) };
  else if (id === 'data') data = buf.subarray(body, Math.min(body + size, buf.length));
  off = body + size + (size & 1);
}
if (!fmt || !data) fail(`${input}: fmt/data 청크 없음`);
const isFloat = fmt.tag === 3;
if (!(fmt.tag === 1 || fmt.tag === 3 || fmt.tag === 0xFFFE)) fail(`${input}: 비PCM WAV(format ${fmt.tag}) 미지원`);
const bps = fmt.bits / 8, frames = Math.floor(data.length / (bps * fmt.ch));
const read = (o) => isFloat ? data.readFloatLE(o) :
  bps === 1 ? (data[o] - 128) / 128 : bps === 2 ? data.readInt16LE(o) / 32768 :
  bps === 3 ? data.readIntLE(o, 3) / 8388608 : data.readInt32LE(o) / 2147483648;
const mono = new Float32Array(frames);
for (let f = 0; f < frames; f++) { let s = 0; for (let c = 0; c < fmt.ch; c++) s += read((f * fmt.ch + c) * bps); mono[f] = s / fmt.ch; }

// ── 리샘플(선형 보간, 다운샘플 시 구간 평균으로 앨리어싱 완화) ──
function resample(x, from, to) {
  if (from === to) return x;
  const n = Math.floor(x.length * to / from), y = new Float32Array(n), r = from / to;
  for (let i = 0; i < n; i++) {
    if (r > 1) { const a = Math.floor(i * r), b = Math.min(x.length, Math.floor((i + 1) * r)); let s = 0; for (let k = a; k < b; k++) s += x[k]; y[i] = s / Math.max(1, b - a); }
    else { const p = i * r, k = Math.floor(p), t = p - k; y[i] = x[k] * (1 - t) + (x[Math.min(k + 1, x.length - 1)] * t); }
  }
  return y;
}
// ── G.711 인코더 (ITU-T G.711 표준 알고리즘) ──
function ulaw(s) {
  const BIAS = 0x84, CLIP = 32635; let sign = (s >> 8) & 0x80; if (sign) s = -s; if (s > CLIP) s = CLIP; s += BIAS;
  let exp = 7; for (let m = 0x4000; (s & m) === 0 && exp > 0; m >>= 1) exp--;
  return ~(sign | (exp << 4) | ((s >> (exp + 3)) & 0x0F)) & 0xFF;
}
function alaw(s) {
  let sign = s >= 0 ? 0x80 : 0; if (!sign) s = -s - 1; if (s > 32767) s = 32767;
  let v; if (s < 256) v = s >> 4; else { let exp = 7; for (let m = 0x4000; (s & m) === 0 && exp > 1; m >>= 1) exp--; v = (exp << 4) | ((s >> (exp + 3)) & 0x0F); }
  return (v | sign) ^ 0x55;
}
for (const o of outputs) {
  const enc = o.fmt === 'mulaw' ? ulaw : o.fmt === 'alaw' ? alaw : null;
  if (!enc) fail(`출력 포맷 -f ${o.fmt} 미지원 (mulaw|alaw)`);
  const y = resample(mono, fmt.rate, o.rate), out = Buffer.alloc(y.length);
  for (let i = 0; i < y.length; i++) out[i] = enc(Math.max(-32768, Math.min(32767, Math.round(y[i] * 32767))));
  fs.writeFileSync(o.file, out);
}
