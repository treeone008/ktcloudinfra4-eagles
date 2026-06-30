'use strict';

const fs = require('fs');

// ── Docker Secret 전용 ───────────────────────────────────────────────────────
function readSecret(name) {
  const secretPath = `/run/secrets/${name}`;
  try {
    return fs.readFileSync(secretPath, 'utf8').trim();
  } catch {
    throw new Error(`[Secret 오류] /run/secrets/${name} 를 읽을 수 없습니다.`);
  }
}

function readOptionalSecret(name) {
  try {
    return fs.readFileSync(`/run/secrets/${name}`, 'utf8').trim();
  } catch {
    return '';
  }
}

const DB_TYPE          = readSecret('db_type');
const DB_PRIMARY_HOST  = readSecret('db_primary_host');
const DB_PRIMARY_PORT  = readSecret('db_primary_port');
const DB_USER          = readSecret('db_user');
const DB_PASSWORD      = readSecret('db_password');
const DB_NAME          = readSecret('db_name');
const DB_REPLICA_HOSTS = readOptionalSecret('db_replica_hosts');

// ── 공통 파싱 ────────────────────────────────────────────────────────────────
function parseHostPort(str, defaultPort) {
  const [host, port] = str.trim().split(':');
  return { host, port: parseInt(port || defaultPort, 10) };
}

function baseConfig() {
  return { user: DB_USER, password: DB_PASSWORD, database: DB_NAME };
}

function buildNodeList() {
  const defaultPort = DB_TYPE === 'postgres' ? 5432 : 3306;
  const primary = parseHostPort(
    `${DB_PRIMARY_HOST}:${DB_PRIMARY_PORT || defaultPort}`,
    defaultPort
  );
  const replicas = DB_REPLICA_HOSTS
    ? DB_REPLICA_HOSTS.split(',').map(s => parseHostPort(s, defaultPort))
    : [];
  return { primary, replicas };
}

// ── MySQL / MariaDB ──────────────────────────────────────────────────────────
function buildMysqlDb() {
  const mysql = require('mysql2/promise');
  const { primary, replicas } = buildNodeList();
  const base = baseConfig();

  const poolCfg = (node) => ({
    ...base,
    host:               node.host,
    port:               node.port,
    waitForConnections: true,
    connectionLimit:    20,
    queueLimit:         200,
    enableKeepAlive:    true,
    keepAliveInitialDelay: 10000,
  });

  const primaryPool  = mysql.createPool(poolCfg(primary));
  const replicaPools = replicas.map(r => mysql.createPool(poolCfg(r)));
  let rrIndex = 0;

  // ── Replica 상태 확인 후 fallback ──────────────────────────────────────────
  async function getReadPool() {
    if (replicaPools.length === 0) return primaryPool;

    const pool = replicaPools[rrIndex % replicaPools.length];
    rrIndex++;

    try {
      // Replica 생존 확인
      await pool.execute('SELECT 1');
      return pool;
    } catch {
      // Replica 죽었으면 Primary로 fallback
      console.warn('[DB] Replica 연결 실패, Primary로 fallback');
      return primaryPool;
    }
  }

  // ── 재시도 포함 쿼리 ────────────────────────────────────────────────────────
  async function query(sql, params, { write = false } = {}, retries = 3) {
    let lastErr;
    for (let i = 0; i < retries; i++) {
      try {
        const pool = write ? primaryPool : await getReadPool();
        const [rows] = await pool.execute(sql, params);
        return rows;
      } catch (err) {
        lastErr = err;
        if (i < retries - 1) {
          console.warn(`[DB] 쿼리 재시도 ${i + 1}/${retries}: ${err.message}`);
          await new Promise(r => setTimeout(r, 1000 * (i + 1))); // 점진적 대기
        }
      }
    }
    throw lastErr;
  }

  async function init() {
    await query(`
      CREATE TABLE IF NOT EXISTS posts (
        id         BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
        title      VARCHAR(300) NOT NULL,
        content    TEXT         NOT NULL,
        created_at DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
        INDEX idx_created (created_at DESC)
      ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
    `, [], { write: true });
  }

  return { query, init };
}

// ── PostgreSQL ───────────────────────────────────────────────────────────────
function buildPostgresDb() {
  const { Pool } = require('pg');
  const { primary, replicas } = buildNodeList();
  const base = baseConfig();

  const poolCfg = (node) => ({
    ...base,
    host:                    node.host,
    port:                    node.port,
    max:                     20,
    idleTimeoutMillis:       30000,
    connectionTimeoutMillis: 3000,
  });

  const primaryPool  = new Pool(poolCfg(primary));
  const replicaPools = replicas.map(r => new Pool(poolCfg(r)));
  let rrIndex = 0;

  async function getReadPool() {
    if (replicaPools.length === 0) return primaryPool;

    const pool = replicaPools[rrIndex % replicaPools.length];
    rrIndex++;

    try {
      await pool.query('SELECT 1');
      return pool;
    } catch {
      console.warn('[DB] Replica 연결 실패, Primary로 fallback');
      return primaryPool;
    }
  }

  async function query(sql, params, { write = false } = {}, retries = 3) {
    let lastErr;
    for (let i = 0; i < retries; i++) {
      try {
        const pool = write ? primaryPool : await getReadPool();
        const res = await pool.query(sql, params);
        return res.rows;
      } catch (err) {
        lastErr = err;
        if (i < retries - 1) {
          console.warn(`[DB] 쿼리 재시도 ${i + 1}/${retries}: ${err.message}`);
          await new Promise(r => setTimeout(r, 1000 * (i + 1)));
        }
      }
    }
    throw lastErr;
  }

  async function init() {
    await query(`
      CREATE TABLE IF NOT EXISTS posts (
        id         BIGSERIAL    PRIMARY KEY,
        title      VARCHAR(300) NOT NULL,
        content    TEXT         NOT NULL,
        created_at TIMESTAMPTZ  NOT NULL DEFAULT NOW()
      )
    `, [], { write: true });
    await query(
      `CREATE INDEX IF NOT EXISTS idx_posts_created ON posts (created_at DESC)`,
      [], { write: true }
    );
  }

  return { query, init };
}

module.exports = DB_TYPE === 'postgres' ? buildPostgresDb() : buildMysqlDb();
