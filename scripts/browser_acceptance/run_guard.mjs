// SPDX-License-Identifier: AGPL-3.0-or-later
import {writeFile, rename} from 'node:fs/promises';
import {SafeCDP, TransportGuard} from './transport_guard.mjs';

// Run persistently before any account interaction. Do not stop this process
// while performing acceptance; a disconnected debugger removes protection.
const args = process.argv.slice(2);
if (args.length !== 2) {
  console.error('Usage: node run_guard.mjs LOOPBACK_CDP_URL AGGREGATE_JSON_PATH');
  process.exit(2);
}
let guard;
const startedAt = new Date().toISOString();
async function publish() {
  const result = {...guard.snapshot(), pid:process.pid, started_at:startedAt,
    heartbeat_at:new Date().toISOString(), expires_at:new Date(Date.now()+3000).toISOString()};
  const temporary = `${args[1]}.tmp.${process.pid}`;
  await writeFile(temporary, JSON.stringify(result, null, 2) + '\n', {mode: 0o600});
  await rename(temporary,args[1]);
  return result;
}
try {
  const cdp = await SafeCDP.connect(args[0]);
  guard = new TransportGuard(cdp);
  await guard.start();
  await publish();
  console.log('GUARD_READY (HTTP Request-stage interception; aggregate evidence only)');
  async function tick() {
    await publish().catch(() => console.error('guard_evidence_write_failed'));
    setTimeout(tick,1000);
  }
  setTimeout(tick,1000);
} catch {
  if (guard) await publish().catch(() => {});
  console.error('GUARD_NOT_READY: acceptance must remain stopped');
  process.exitCode = 1;
}
