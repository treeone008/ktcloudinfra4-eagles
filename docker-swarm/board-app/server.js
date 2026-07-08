'use strict';

const path    = require('path');
const crypto  = require('crypto');
const os      = require('os');

const fastify = require('fastify')({
  logger: true,
  keepAliveTimeout: 30000,
  connectionTimeout: 10000,
});

const db = require('./db');

// ── 컨테이너 IP 조회 ──────────────────────────────────────────────────────────
function getContainerIPs() {
  return Object.values(os.networkInterfaces())
    .flat()
    .filter(i => i.family === 'IPv4' && !i.internal)
    .map(i => i.address)
    .filter(ip => !ip.startsWith('172.'));  // ingress 네트워크 제외
}

// ── DB 에러 분류 ──────────────────────────────────────────────────────────────
function isConnectionError(err) {
  return [
    'ECONNREFUSED',
    'ECONNRESET',
    'ETIMEDOUT',
    'PROTOCOL_CONNECTION_LOST',
    'ER_ACCESS_DENIED_ERROR',
  ].includes(err.code);
}

// ── Plugin 등록 ───────────────────────────────────────────────────────────────
fastify.register(require('@fastify/cookie'));
fastify.register(require('@fastify/static'), {
  root:   path.join(__dirname, 'public'),
  prefix: '/',
  index:  false,
});

// ── 세션 쿠키 ────────────────────────────────────────────────────────────────
function ensureSession(req, reply) {
  let sid = req.cookies.sid;
  if (!sid) {
    sid = crypto.randomUUID();
    reply.setCookie('sid', sid, {
      path:     '/',
      httpOnly: true,
      sameSite: 'lax',
      maxAge:   60 * 60 * 24 * 30,
    });
  }
  return sid;
}

// ── index.html 서빙 (세션 먼저 발급) ─────────────────────────────────────────
fastify.get('/', async (req, reply) => {
  ensureSession(req, reply);
  return reply.sendFile('index.html');
});

// ── API: 세션 확인 + 컨테이너 IP ─────────────────────────────────────────────
fastify.get('/api/session', async (req, reply) => {
  const sid = ensureSession(req, reply);
  return {
    sid,
    container_ips: getContainerIPs(),
  };
});

// ── API: 글 목록 (replica → fallback primary) ────────────────────────────────
fastify.get('/api/posts', async (req, reply) => {
  ensureSession(req, reply);
  const page   = Math.max(1, parseInt(req.query.page || '1', 10));
  const limit  = 20;
  const offset = (page - 1) * limit;

  try {
    const rows = await db.query(
      'SELECT id, title, created_at FROM posts ORDER BY created_at DESC LIMIT ? OFFSET ?',
      [limit, offset]
    );
    return { posts: rows, page, limit };
  } catch (err) {
    if (isConnectionError(err)) {
      return reply.code(503).send({
        error: '일시적으로 서비스가 불안정합니다. 잠시 후 다시 시도해주세요.'
      });
    }
    throw err;
  }
});

// ── API: 글 상세 (replica → fallback primary) ────────────────────────────────
fastify.get('/api/posts/:id', async (req, reply) => {
  ensureSession(req, reply);

  try {
    const rows = await db.query(
      'SELECT id, title, content, created_at FROM posts WHERE id = ?',
      [req.params.id]
    );
    if (!rows.length) return reply.code(404).send({ error: '글을 찾을 수 없습니다' });
    return rows[0];
  } catch (err) {
    if (isConnectionError(err)) {
      return reply.code(503).send({
        error: '일시적으로 서비스가 불안정합니다. 잠시 후 다시 시도해주세요.'
      });
    }
    throw err;
  }
});

// ── API: 글 쓰기 (primary) ───────────────────────────────────────────────────
fastify.post('/api/posts', {
  schema: {
    body: {
      type: 'object',
      required: ['title', 'content'],
      properties: {
        title:   { type: 'string', minLength: 1, maxLength: 300 },
        content: { type: 'string', minLength: 1 },
      },
    },
  },
}, async (req, reply) => {
  ensureSession(req, reply);
  const { title, content } = req.body;

  try {
    const result = await db.query(
      'INSERT INTO posts (title, content) VALUES (?, ?)',
      [title, content],
      { write: true }
    );
    return reply.code(201).send({ id: result.insertId });
  } catch (err) {
    if (isConnectionError(err)) {
      return reply.code(503).send({
        error: '현재 글 작성이 일시적으로 불가합니다. 잠시 후 다시 시도해주세요.'
      });
    }
    throw err;
  }
});

// ── Health check ─────────────────────────────────────────────────────────────
fastify.get('/health', async (req, reply) => {
  try {
    await db.query('SELECT 1', [], { write: false });
    return { status: 'ok', db: 'ok' };
  } catch {
    return reply.code(503).send({ status: 'unhealthy', db: 'error' });
  }
});

// ── 시작 ─────────────────────────────────────────────────────────────────────
async function start() {
  try {
    await db.init();
    await fastify.listen({
      port: parseInt(process.env.PORT || '3000', 10),
      host: process.env.HOST || '0.0.0.0',
    });
  } catch (err) {
    fastify.log.error(err);
    process.exit(1);
  }
}

start();