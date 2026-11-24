import { initdb, pg_ctl } from '@embedded-postgres/windows-x64';
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const dataDir = path.join(root, process.env.GYMOS_PGDATA || '.pgdata');
const port = process.env.GYMOS_PGPORT || '55432';
const cmd = process.argv[2];

function run(exe, args, allowFail = false) {
  const r = spawnSync(exe, args, { stdio: 'inherit', cwd: root });
  if (r.status !== 0 && !allowFail) process.exit(r.status ?? 1);
  return r.status ?? 1;
}

if (cmd === 'init') {
  if (fs.existsSync(path.join(dataDir, 'PG_VERSION'))) {
    console.log('cluster already initialised at ' + dataDir);
  } else {
    fs.mkdirSync(dataDir, { recursive: true });
    run(initdb, ['-D', dataDir, '-U', 'postgres', '-A', 'trust', '-E', 'UTF8', '--locale=C']);
  }
} else if (cmd === 'start') {
  run(pg_ctl, ['-D', dataDir, '-l', path.join(root, 'pg.log'), '-o', `-p ${port} -c listen_addresses=127.0.0.1`, '-w', '-t', '30', 'start']);
} else if (cmd === 'stop') {
  run(pg_ctl, ['-D', dataDir, '-m', 'fast', '-w', 'stop'], true);
} else if (cmd === 'status') {
  process.exit(run(pg_ctl, ['-D', dataDir, 'status'], true));
} else {
  console.log('usage: node pg_cluster.mjs init|start|stop|status');
  process.exit(1);
}