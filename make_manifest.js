// Generate signed app manifest.json for the new release (v2.5.2).
// Canonical rule must match lib/services/update_service.dart & verify_manifest.py.
// Output: build/dist/manifest.json
'use strict';
const crypto = require('crypto');
const fs = require('fs');
const path = require('path');

const VERSION = process.env.APP_VERSION || '2.5.6';
const BUILD = parseInt(process.env.APP_BUILD || '29900000', 10);
const EXE_REL = `/app/v${VERSION}/scum_mod_manager.zip`;
const CHANGELOG = process.env.APP_CHANGELOG || 'fix: hotfix 重发 v2.5.6 — 修复 dart-define 未注入导致版本号不变 + 排除 .bak 备份文件';

function esc(s) {
  return s.replace(/\\/g, '\\\\').replace(/\n/g, '\\n');
}

const exe = path.join('build', 'windows', 'x64', 'runner', 'Release', 'scum_mod_manager.zip');
const exeBytes = fs.readFileSync(exe);
const exeSha256 = crypto.createHash('sha256').update(exeBytes).digest('hex');
const releasedAt = new Date().toISOString();

const canonical = [
  `build=${BUILD}`,
  `changelog=${esc(CHANGELOG)}`,
  `exe_sha256=${exeSha256}`,
  `exe_size_bytes=${exeBytes.length}`,
  `exe_url=${EXE_REL}`,
  `released_at=${releasedAt}`,
  `version=${VERSION}`,
].join('\n');

const secret = JSON.parse(fs.readFileSync('update_secret.json', 'utf8'));
const key = Buffer.from(secret.UPDATE_VERIFY_KEY, 'hex');
const signature = crypto.createHmac('sha256', key).update(canonical).digest('base64');

const manifest = {
  version: VERSION,
  build: BUILD,
  released_at: releasedAt,
  exe_url: EXE_REL,
  exe_sha256: exeSha256,
  exe_size_bytes: exeBytes.length,
  changelog: CHANGELOG,
  signature,
};

fs.mkdirSync(path.join('build', 'dist'), { recursive: true });
const out = path.join('build', 'dist', 'manifest.json');
fs.writeFileSync(out, JSON.stringify(manifest, null, 2) + '\n', 'utf8');

// self-verify (mirror of verify_manifest.py)
const recomputed = crypto.createHmac('sha256', key).update(canonical).digest('base64');
console.log('manifest written :', out);
console.log('version          :', VERSION);
console.log('exe_size_bytes   :', exeBytes.length);
console.log('exe_sha256       :', exeSha256);
console.log('signature OK     :', recomputed === signature);
console.log('changelog        :', CHANGELOG);
