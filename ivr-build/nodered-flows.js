#!/usr/bin/env node
// aicc-ivr-nodered 보조 스크립트 — settings.js 렌더링 / flows 시딩 (nodered-entrypoint.sh 가 호출)
//   node nodered-flows.js settings <template> <out>
//   node nodered-flows.js seed <src flows.json> <userDir>
'use strict';
const fs = require('fs');
const path = require('path');
const env = process.env;
const log = (m) => console.log('[nodered-entrypoint] ' + m);

function renderSettings(tpl, out) {
  let s = fs.readFileSync(tpl, 'utf8');
  const ver = JSON.parse(fs.readFileSync('/opt/nodered/user/jedai_module/node-red-contrib-ivr-scenario/package.json')).version;
  // install_scenario.sh 의 sed 치환과 동일
  s = s.split('${NODERED_PORT}').join(env.NODERED_PORT || '1890')
       .split('${VERSION}').join(ver)
       .split('${USER}').join(env.IVR_USER || 'ivr');
  // 관리자(admin) 비밀번호 bcrypt 해시 교체 (Secret NODERED_ADMIN_PASSWORD_HASH, 없으면 패키지 기본값 유지)
  if (env.NODERED_ADMIN_PASSWORD_HASH) {
    s = s.replace(/(password:\s*")\$2[aby]\$[^"]+(")/, (_, a, b) => a + env.NODERED_ADMIN_PASSWORD_HASH + b);
  }
  // 컨테이너 전용 항목: flows 파일명 고정(기본값 flows_<hostname>.json 은 hostNetwork 노드 이동 시 바뀜),
  // 자격증명 암호키를 Secret 에서 주입(미지정 시 .config.runtime.json 자동키 — PVC 에 함께 보존됨)
  const extra = [
    "    flowFile: 'flows.json',",
    "    credentialSecret: process.env.NODERED_CREDENTIAL_SECRET || undefined,",
  ].join('\n');
  s = s.replace(/module\.exports\s*=\s*\{/, (m) => m + '\n' + extra);
  fs.writeFileSync(out, s);
}

// flows 템플릿 CONFIG 탭의 MySQLdatabase 노드(uivr / JEDAI_CUBE)를 env 로 맞춘다.
// 매뉴얼은 편집기에서 CONFIG 탭 Unlock 후 수동 입력하던 단계 — 시딩 시점에 자동화.
function seedFlows(src, userDir) {
  const flows = JSON.parse(fs.readFileSync(src, 'utf8'));
  const creds = {};
  const ivrDb = env.IVR_DB_NAME || 'uivr';
  for (const n of flows) {
    if (n.type !== 'MySQLdatabase') continue;
    const isCti = /JEDAI_CUBE/i.test(n.db || '');
    const host = isCti ? (env.CTI_DB_HOST || env.IVR_DB_HOST) : env.IVR_DB_HOST;
    const port = isCti ? (env.CTI_DB_PORT || env.IVR_DB_PORT) : env.IVR_DB_PORT;
    const user = isCti ? (env.CTI_DB_USER || env.IVR_DB_USER) : env.IVR_DB_USER;
    const pass = isCti ? (env.CTI_DB_PASSWORD || env.IVR_DB_PASSWORD) : env.IVR_DB_PASSWORD;
    if (host) n.host = host;
    if (port) n.port = String(port);
    if (!isCti && n.db === 'uivr') n.db = ivrDb;
    if (isCti && env.CTI_DB_NAME) n.db = env.CTI_DB_NAME;
    if (user && pass) creds[n.id] = { user, password: pass };
    log(`flows: MySQLdatabase ${n.id} → ${n.host}:${n.port}/${n.db}`);
  }
  fs.writeFileSync(path.join(userDir, 'flows.json'), JSON.stringify(flows, null, 4));
  // 자격증명은 Node-RED 와 같은 방식(aes-256-ctr, key=sha256(credentialSecret), "$"=iv(hex)+base64)으로 암호화해 둔다.
  // 평문으로 두면 Node-RED 는 읽기만 하고 자격증명이 바뀌기 전까지 다시 저장하지 않아 PVC 에 평문이 남는다(검증으로 확인).
  const credFile = path.join(userDir, 'flows_cred.json');
  if (!Object.keys(creds).length || fs.existsSync(credFile)) return;
  if (!env.NODERED_CREDENTIAL_SECRET) {
    log('[WARN] NODERED_CREDENTIAL_SECRET 미지정 — DB 자격증명 주입 생략 (편집기 CONFIG 탭에서 직접 입력)');
    return;
  }
  const crypto = require('crypto');
  const key = crypto.createHash('sha256').update(env.NODERED_CREDENTIAL_SECRET).digest();
  const iv = crypto.randomBytes(16);
  const c = crypto.createCipheriv('aes-256-ctr', key, iv);
  const enc = { '$': iv.toString('hex') + c.update(JSON.stringify(creds), 'utf8', 'base64') + c.final('base64') };
  fs.writeFileSync(credFile, JSON.stringify(enc), { mode: 0o600 });
}

const [cmd, a, b] = process.argv.slice(2);
if (cmd === 'settings') renderSettings(a, b);
else if (cmd === 'seed') seedFlows(a, b);
else { console.error('usage: nodered-flows.js settings|seed ...'); process.exit(2); }
