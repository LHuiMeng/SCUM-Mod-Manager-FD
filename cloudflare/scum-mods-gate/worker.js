/**
 * SCUM Mods R2 门禁网关（Cloudflare Worker）
 * -------------------------------------------------------------------------
 * 作用：把 R2 桶 `scum-mods` 的**唯一**公网入口收敛到本 Worker，并在入口处
 *       校验启动器令牌 —— 只有携带正确 `X-Scum-Gate` 头的请求才能取到对象，
 *       其余一律 403。R2 桶自身的公开自定义域会被删除，桶只对本 Worker 的
 *       R2 绑定可见，从而实现「只有启动器的访问能从 CF R2 下载 mod」。
 *
 * 路由：GET/HEAD /<key>          → R2 对象 <key>（如 mods/<id>/pak）
 *       GET      /health          → {"gate":"up"}（不含任何数据，仅探活）
 *       其它方法                   → 405
 *
 * Range：完整支持（206 + Content-Range + Content-Length），客户端
 *       `_probeDownload` 依赖 `Range: bytes=0-0` → 206 判定可分段并发下载。
 *
 * 令牌：Worker secret `GATE_TOKEN`（`wrangler secret put GATE_TOKEN`），
 *       与服务器安装包内的共享密钥同值。**绝不写进本文件**。
 *
 * 部署：wrangler.toml（R2 绑定 MODS + 自定义域路由），见同目录 README。
 */

const TOKEN_HEADER = 'X-Scum-Gate';
function authorize(request, env) {
  const gate = env.GATE_TOKEN || '';
  if (!gate) return false;
  const authorization = request.headers.get('authorization') || '';
  const bearer = authorization.startsWith('Bearer ') ? authorization.slice(7).trim() : '';
  const provided = request.headers.get(TOKEN_HEADER) || bearer;
  return timingSafeEqualStr(provided, gate);
}

/** 常量时间字符串比较（长度不同直接 false，不泄露前缀信息）。 */
function timingSafeEqualStr(a, b) {
  const enc = new TextEncoder();
  const A = enc.encode(a);
  const B = enc.encode(b);
  if (A.length !== B.length) return false;
  let diff = 0;
  for (let i = 0; i < A.length; i++) diff |= A[i] ^ B[i];
  return diff === 0;
}

/** 解析 Range 头 → {offset, length}；不可解析返回 null；越界返回 undefined。 */
function parseRange(header, size) {
  if (!header) return null;
  const m = /^bytes=(\d*)-(\d*)$/.exec(header.trim());
  if (!m) return null;
  const startStr = m[1];
  const endStr = m[2];
  if (startStr === '' && endStr === '') return null;
  let offset;
  let length;
  if (startStr === '') {
    const suffix = parseInt(endStr, 10);
    if (suffix <= 0) return undefined;
    offset = Math.max(0, size - suffix);
    length = size - offset;
  } else {
    offset = parseInt(startStr, 10);
    if (endStr === '') {
      length = size - offset;
    } else {
      const end = parseInt(endStr, 10);
      if (end < offset) return undefined;
      length = end - offset + 1;
    }
    if (length > size - offset) length = size - offset;
  }
  if (offset >= size || length <= 0) return undefined;
  return { offset, length };
}

function baseHeaders(meta, key) {
  const h = new Headers();
  h.set('accept-ranges', 'bytes');
  h.set('etag', meta.httpEtag);
  // 门禁资源：不允许中间缓存（缓存会绕过令牌）。
  h.set('cache-control', 'private, no-store');
  const ct = (meta.httpMetadata && meta.httpMetadata.contentType) ||
    'application/octet-stream';
  h.set('content-type', ct);
  const name = key.split('/').pop() || 'download';
  h.set('content-disposition', `attachment; filename="${name}"`);
  return h;
}

/** key 合法性：非空、不含空段、不含 `..` 段（防路径穿越）。 */
function safeKey(pathname) {
  let key;
  try {
    key = decodeURIComponent(pathname.replace(/^\/+/, ''));
  } catch (_) {
    return null;
  }
  if (!key || key.length > 512) return null;
  const segs = key.split('/');
  for (const s of segs) {
    if (s === '' || s === '.' || s === '..') return null;
  }
  return key;
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);

    // 探活（无数据，无需令牌）。
    if (url.pathname === '/health') {
      return new Response(JSON.stringify({ gate: 'up' }), {
        status: 200,
        headers: { 'content-type': 'application/json; charset=utf-8' },
      });
    }

    if (request.method !== 'GET' && request.method !== 'HEAD') {
      return new Response('Method Not Allowed', {
        status: 405,
        headers: { allow: 'GET, HEAD' },
      });
    }

    if (!env.GATE_TOKEN) {
      return new Response('gate not configured', { status: 503 });
    }
    if (!authorize(request, env)) {
      return new Response(
        JSON.stringify({
          error: 'forbidden',
          hint: 'launcher gate token required',
        }),
        {
          status: 403,
          headers: {
            'content-type': 'application/json; charset=utf-8',
            'cache-control': 'no-store',
          },
        },
      );
    }

    const key = safeKey(url.pathname);
    if (!key) return new Response('Not Found', { status: 404 });

    const meta = await env.MODS.head(key);
    if (meta === null) {
      return new Response('Not Found', {
        status: 404,
        headers: { 'cache-control': 'no-store' },
      });
    }

    const size = meta.size;
    const rangeHeader = request.headers.get('range');
    const range = parseRange(rangeHeader, size);

    if (rangeHeader && range === undefined) {
      // 越界 / 不可满足。
      const h = new Headers();
      h.set('content-range', `bytes */${size}`);
      h.set('cache-control', 'no-store');
      return new Response('Range Not Satisfiable', { status: 416, headers: h });
    }

    if (request.method === 'HEAD') {
      const h = baseHeaders(meta, key);
      h.set('content-length', String(range ? range.length : size));
      if (range) {
        h.set(
          'content-range',
          `bytes ${range.offset}-${range.offset + range.length - 1}/${size}`,
        );
      }
      return new Response(null, { status: range ? 206 : 200, headers: h });
    }

    const obj = range
      ? await env.MODS.get(key, { range: { offset: range.offset, length: range.length } })
      : await env.MODS.get(key);
    if (obj === null) return new Response('Not Found', { status: 404 });

    const headers = baseHeaders(meta, key);
    if (range) {
      headers.set('content-length', String(range.length));
      headers.set(
        'content-range',
        `bytes ${range.offset}-${range.offset + range.length - 1}/${size}`,
      );
      return new Response(obj.body, { status: 206, headers });
    }
    headers.set('content-length', String(size));
    return new Response(obj.body, { status: 200, headers });
  },
};
