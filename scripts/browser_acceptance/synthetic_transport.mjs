// SPDX-License-Identifier: AGPL-3.0-or-later
// Uses only a fresh, disposable local Chrome profile and loopback fixture.
import {createServer} from 'node:http';
import {mkdtemp, readFile, rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {spawn} from 'node:child_process';
import {once} from 'node:events';
import assert from 'node:assert/strict';
import {SafeCDP, TransportGuard} from './transport_guard.mjs';
const rawReloadNegative = process.argv.includes('--raw-reload-negative');

const backupFixture = JSON.stringify({rooms:{'!fiction:local':{sessions:{fiction:{
  first_message_index:0,forwarded_count:0,is_verified:false,
  session_data:{ephemeral:'ZmljdGlvbg',ciphertext:'ZmljdGlvbg',mac:'ZmljdGlvbg'},
}}}}});
const forbiddenRoutes = [
  ['PUT', '/rooms/fiction/send/m.room.message/txn'],
  ['PUT', '/rooms/fiction/send/m.reaction/txn'],
  ['PUT', '/rooms/fiction/redact/fiction/txn'],
  ['PUT', '/rooms/fiction/state/m.room.name'],
  ['POST', '/rooms/fiction/receipt/m.read/fiction'],
  ['POST', '/rooms/fiction/read_markers'],
  ['PUT', '/rooms/fiction/typing/fiction'],
  ['PUT', '/presence/fiction/status'],
  ['PUT', '/user/fiction/account_data/m.direct'],
  ['PUT', '/room_keys/keys?version=fiction', '{"rooms":{},"session_key":"fiction"}'],
  ['PUT', '/room_keys/keys?version=fiction', '{"rooms":{"session_key":"fiction"},"rooms":{}}'],
  ['DELETE', '/room_keys/keys?version=fiction'],
  ['POST', '/room_keys/version'],
];
const allowedRoutes = [
  ['GET', '/sync?set_presence=offline'], ['POST', '/keys/query'],
  ['POST', '/keys/claim'], ['POST', '/keys/upload'],
  ['PUT', '/sendToDevice/m.room.encrypted/txn'],
  ['POST', '/user/@fiction:local/filter'],
  ['PUT', '/room_keys/keys?version=fiction', backupFixture],
];
const probe = `async function probe(){
  const forbidden=${JSON.stringify(forbiddenRoutes)};
  const allowed=${JSON.stringify(allowedRoutes)};
  let blocked=0, passed=0;
  for(const [method,path,body] of forbidden) {
    try { await fetch('/_matrix/client/v3'+path,{method,body:body??'{}'}); }
    catch { blocked++; }
  }
  for(const [method,path,body] of allowed) {
    try {const response=await fetch('/_matrix/client/v3'+path,{method,...(method==='GET'?{}:{body:body??'{}'})}); if(response.ok) passed++;}
    catch {}
  }
  return {blocked,passed};
}`;
let forbiddenTransmitted = 0, allowedTransmitted = 0, websocketTransmitted = 0, canceledTransmitted = 0;
const server = createServer((req, res) => {
  res.setHeader('Content-Type', 'application/javascript');
  if (req.url === '/') {
    res.setHeader('Content-Type', 'text/html');
    res.end('<!doctype html><title>Synthetic transport fixture</title>');
  } else if (req.url === '/worker.js') {
    res.end(`${probe}; probe().then(result=>postMessage(result));`);
  } else if (req.url === '/cancel-worker.js') {
    res.end(`const controller=new AbortController();setTimeout(()=>controller.abort(),30);fetch('/cancel-probe/worker',{signal:controller.signal}).then(()=>postMessage(false)).catch(error=>postMessage(error.name==='AbortError'));`);
  } else if (req.url === '/terminate-worker.js') {
    res.end(`fetch('/cancel-probe/worker_terminate').catch(()=>{});`);
  } else if (req.url.startsWith('/cancel-probe/')) {
    canceledTransmitted++;res.end('{}');
  } else if (req.url === '/sw.js') {
    res.setHeader('Service-Worker-Allowed', '/');
    res.end(`${probe}; const startupProbe=probe(); self.addEventListener('install',event=>event.waitUntil(self.skipWaiting())); self.addEventListener('activate',event=>event.waitUntil(self.clients.claim())); self.addEventListener('message',event=>event.waitUntil(startupProbe.then(result=>event.ports[0].postMessage(result))));`);
  } else if (req.url.startsWith('/_matrix/client/v3/')) {
    const route = req.url.slice('/_matrix/client/v3'.length);
    const candidate = allowedRoutes.find(([method,path]) => req.method === method && route === path);
    if (candidate?.[2]) {
      let body='';req.on('data',chunk=>{body+=chunk;});req.on('end',()=>{
        if(body===candidate[2]) allowedTransmitted++;else forbiddenTransmitted++;
        res.end('{}');
      });
    } else {
      if(candidate) allowedTransmitted++;else forbiddenTransmitted++;
      req.resume();res.end('{}');
    }
  } else {res.statusCode=404;res.end('{}');}
});
server.on('upgrade', (_req, socket) => {websocketTransmitted++; socket.destroy();});
await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
const origin = `http://127.0.0.1:${server.address().port}`;
const corsCounts = {preflight:0,offline_get:0,unsafe_get:0,authorization_seen:false};
const corsServer = createServer((req,res) => {
  res.setHeader('Access-Control-Allow-Origin',origin);
  res.setHeader('Access-Control-Allow-Methods','GET');
  res.setHeader('Access-Control-Allow-Headers','Authorization');
  res.setHeader('Access-Control-Max-Age','0');
  if(req.method==='OPTIONS') {
    corsCounts.preflight++; res.statusCode=204; res.end(); return;
  }
  if(req.method==='GET') {
    const offline = new URL(req.url,'http://synthetic.invalid').searchParams.get('set_presence')==='offline';
    corsCounts[offline?'offline_get':'unsafe_get']++;
    corsCounts.authorization_seen ||= req.headers.authorization === 'synthetic-fixture';
  }
  res.setHeader('Content-Type','application/json');res.end('{}');
});
await new Promise(resolve=>corsServer.listen(0,'127.0.0.1',resolve));
const corsOrigin = `http://127.0.0.1:${corsServer.address().port}`;
const profile = await mkdtemp(join(tmpdir(), 'personal-transport-synthetic-'));
const browser = spawn(process.env.CHROME_BIN || '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome', [
  '--headless=new', '--remote-debugging-address=127.0.0.1', '--remote-debugging-port=0',
  `--user-data-dir=${profile}`, '--no-first-run', '--no-default-browser-check',
  '--disable-sync', '--disable-background-networking', '--disable-extensions', 'about:blank',
], {stdio: 'ignore'});
let cdp, guard;
try {
  let port;
  for(let tries=0; tries<100; tries++) {
    try {port=(await readFile(join(profile,'DevToolsActivePort'),'utf8')).split('\n')[0];break;} catch {}
    await new Promise(resolve=>setTimeout(resolve,50));
  }
  assert.ok(port, 'synthetic_browser_start');
  cdp = await SafeCDP.connect(`http://127.0.0.1:${port}`);
  guard = new TransportGuard(cdp); await guard.start();
  const pageSession = [...guard.sessions.entries()].find(([,state])=>state.type==='page')?.[0];
  assert.ok(pageSession, 'synthetic_page');
  await cdp.send('Page.enable', {}, pageSession);
  await cdp.send('Page.navigate', {url:origin}, pageSession);
  for(let tries=0; tries<100; tries++) {
    const ready=await cdp.send('Runtime.evaluate',{expression:`location.origin === ${JSON.stringify(origin)} && document.readyState === 'complete'`,returnByValue:true},pageSession);
    if(ready.result?.value) break;
    await new Promise(resolve=>setTimeout(resolve,50));
  }
  const evaluate = async expression => {
    const value=await cdp.send('Runtime.evaluate',{expression,returnByValue:true,awaitPromise:true},pageSession);
    if(value.exceptionDetails) throw new Error('synthetic_evaluation_failed');
    return value.result.value;
  };
  // Test-only delay: keep the real continue command unsent until the browser
  // itself aborts/reloads. Actual Chrome must then return the missing-ID error
  // and provide a matching positive Network/target cancellation fact.
  const realSend=cdp.send.bind(cdp);const held=new Map();let nextHold;
  cdp.prependListener('event',event=>{
    if(event.method==='Fetch.requestPaused' && nextHold &&
      new URL(event.params.request.url).pathname===`/cancel-probe/${nextHold.kind}`) {
      held.set(event.params.requestId,nextHold);nextHold.resolvePaused();
    }
  });
  cdp.send=(method,params={},sessionId)=>{
    const hold=method==='Fetch.continueRequest'?held.get(params.requestId):null;
    return hold?hold.gate.then(()=>realSend(method,params,sessionId)):realSend(method,params,sessionId);
  };
  const holdNext=kind=>{
    const state={kind};state.gate=new Promise(resolve=>{state.release=resolve;});
    state.paused=new Promise((resolve,reject)=>{
      const timer=setTimeout(()=>reject(new Error('synthetic_pause_timeout')),3000);
      state.resolvePaused=()=>{clearTimeout(timer);resolve();};
    });nextHold=state;return state;
  };
  const pageResult = await evaluate(`(async()=>{${probe};return probe();})()`);
  const workerResult = await evaluate(`new Promise((resolve,reject)=>{const worker=new Worker('/worker.js'); worker.onmessage=event=>{resolve(event.data);worker.terminate();};worker.onerror=()=>reject(new Error('worker_fixture'));})`);
  const serviceWorkerResult = await evaluate(`(async()=>{await navigator.serviceWorker.register('/sw.js');const registration=await navigator.serviceWorker.ready;return new Promise(resolve=>{const channel=new MessageChannel();channel.port1.onmessage=event=>resolve(event.data);registration.active.postMessage('probe',[channel.port2]);});})()`);
  await guard.settle();
  assert.equal(guard.snapshot().harness_errors,0,'no_http_harness_errors');
  assert.equal(guard.isGuarded(),true,'all_http_targets_guarded_before_adversarial_websocket');
  const corsResult = await evaluate(`(async()=>{
    const origin=${JSON.stringify(corsOrigin)};
    const result={offline_success:false,missing_rejected:false,online_rejected:false};
    for(const [query,key] of [['?set_presence=offline','offline_success'],['','missing_rejected'],['?set_presence=online','online_rejected']]) {
      try {const response=await fetch(origin+'/_matrix/client/v3/sync'+query,{headers:{Authorization:'synthetic-fixture'}});result[key]=key==='offline_success'&&response.ok;}
      catch {result[key]=key!=='offline_success';}
    }
    return result;
  })()`);
  assert.deepEqual(corsResult,{offline_success:true,missing_rejected:true,online_rejected:true},'cors_actual_GET_policy');
  assert.equal(corsCounts.preflight,3,'three_genuine_authorization_preflights_reached_fixture');
  assert.equal(corsCounts.offline_get,1,'cross_origin_offline_GET_transmitted');
  assert.equal(corsCounts.unsafe_get,0,'unsafe_cross_origin_GET_never_transmitted');
  assert.equal(corsCounts.authorization_seen,true,'actual_cross_origin_authorization_fixture');
  assert.equal(guard.counters['page:sync_reason:OPTIONS:options_preflight'],3,'preflight_classification_observed');
  assert.equal(guard.counters['page:sync_reason:GET:presence_missing'],1,'missing_presence_classification_observed');
  assert.equal(guard.counters['page:sync_reason:GET:presence_non_offline'],1,'nonoffline_presence_classification_observed');
  const cancellationProofs=[];
  for(const kind of ['abort','worker','worker_terminate','reload']) {
    const hold=holdNext(kind);
    const before=guard.snapshot().confirmed_cancellations;
    let pending;
    if(kind==='abort') {
      pending=evaluate(`(async()=>{const controller=new AbortController();setTimeout(()=>controller.abort(),30);try{await fetch('/cancel-probe/abort',{signal:controller.signal});return false;}catch(error){return error.name==='AbortError';}})()`);
    } else if(kind==='worker') {
      pending=evaluate(`new Promise(resolve=>{window.fixtureCancelWorker=new Worker('/cancel-worker.js');window.fixtureCancelWorker.onmessage=event=>resolve(event.data);})`);
    } else if(kind==='worker_terminate') {
      await evaluate(`window.fixtureTerminateWorker=new Worker('/terminate-worker.js');true`);
    } else {
      await evaluate(rawReloadNegative
        ? `window.fixturePendingFetch=fetch('/cancel-probe/reload').catch(()=>false);true`
        : `window.fixturePendingController=new AbortController();window.addEventListener('beforeunload',()=>window.fixturePendingController.abort(),{once:true});window.fixturePendingFetch=fetch('/cancel-probe/reload',{signal:window.fixturePendingController.signal}).catch(()=>false);true`);
    }
    await hold.paused;
    if(kind==='worker_terminate') {
      await evaluate('window.fixtureTerminateWorker.terminate();true');
      await new Promise(resolve=>setTimeout(resolve,50));
    } else if(kind==='reload') {
      const loaded=new Promise((resolve,reject)=>{
        const timer=setTimeout(()=>reject(new Error('synthetic_reload_timeout')),3000);
        const listener=event=>{if(event.method==='Page.loadEventFired'&&event.sessionId===pageSession){clearTimeout(timer);cdp.off('event',listener);resolve();}};
        cdp.on('event',listener);
      });
      await cdp.send('Page.reload',{},pageSession);await loaded;
    } else assert.equal(await pending,true,'browser_abort_observed');
    hold.release();nextHold=null;
    await guard.settle();
    if(kind==='reload' && rawReloadNegative) {
      assert.equal(guard.snapshot().confirmed_cancellations,before,'raw_reload_has_no_positive_proof');
      assert.equal(guard.snapshot().harness_errors,1,'unproven_raw_reload_stays_sticky');
      assert.equal(guard.isGuarded(),false,'unproven_raw_reload_cannot_retain_readiness');
      cancellationProofs.push({kind:'raw_reload_without_proof',confirmed:false,sticky_unready:true});
    } else {
      assert.equal(guard.snapshot().confirmed_cancellations,before+1,`${kind}_positive_cancellation_proof`);
      assert.equal(guard.snapshot().harness_errors,0,`${kind}_no_false_harness_fault`);
      assert.equal(guard.isGuarded(),true,`${kind}_readiness_retained_with_proof`);
      cancellationProofs.push({kind,confirmed:true});
    }
    if(kind==='worker') await evaluate('window.fixtureCancelWorker.terminate();true');
  }
  assert.equal(canceledTransmitted,0,'canceled_requests_never_reached_fixture');
  const websocketBlocked = rawReloadNegative ? null : await evaluate(`new Promise(resolve=>{const socket=new WebSocket(${JSON.stringify(origin.replace('http:', 'ws:')+'/socket')});socket.onopen=()=>{socket.close();resolve(false);};socket.onerror=()=>resolve(true);setTimeout(()=>resolve(false),2000);})`);
  for(const result of [pageResult,workerResult,serviceWorkerResult]) {
    assert.equal(result.blocked,forbiddenRoutes.length,'all_forbidden_rejected');
    assert.equal(result.passed,allowedRoutes.length,'natural_crypto_sync_pass');
  }
  assert.equal(forbiddenTransmitted,0,'zero_forbidden_reached_fixture');
  assert.equal(allowedTransmitted,allowedRoutes.length*3,'allowed_reached_fixture');
  // Chrome does not intercept websocket handshakes with Fetch/setBlockedURLs.
  // Prove that this unsupported transport invalidates readiness, without ever
  // claiming its detection prevented transmission.
  assert.equal(websocketTransmitted,rawReloadNegative?0:1,'websocket_prevention_unavailable');
  if(!rawReloadNegative) assert.equal(websocketBlocked,true,'websocket_client_rejected');
  await guard.settle();
  assert.equal(guard.snapshot().blocked_attempts,forbiddenRoutes.length*3+2);
  assert.equal(guard.counters['page:blocked:send_or_reaction'],4,'page_plus_owner_worker_actual_interception');
  assert.equal(guard.counters['service_worker:blocked:send_or_reaction'],2,'service_worker_actual_interception');
  assert.ok(guard.counters['worker:network_observed']>=allowedRoutes.length,'worker_network_observed');
  assert.equal(guard.counters['page:allow:natural_sync_filter:POST'],2,'page_and_dedicated_worker_filter_pass');
  assert.equal(guard.counters['service_worker:allow:natural_sync_filter:POST'],1,'service_worker_filter_pass');
  assert.equal(guard.counters['page:allow:natural_crypto_backup:PUT'],2,'page_and_worker_backup_pass');
  assert.equal(guard.counters['service_worker:allow:natural_crypto_backup:PUT'],1,'service_worker_backup_pass');
  assert.equal(guard.snapshot().guarded,false,'unsupported_transport_invalidates_guard');
  assert.equal(guard.snapshot().unsupported_transports,rawReloadNegative?0:1,'unsupported_transport_detected');
  console.log(JSON.stringify({synthetic:'PASS',mode:rawReloadNegative?'RAW_RELOAD_NEGATIVE':'POSITIVE_CANCELLATION',forbidden_transmitted:forbiddenTransmitted,
    allowed_transmitted:allowedTransmitted,websocket_transmitted:websocketTransmitted,
    websocket_prevention:'UNAVAILABLE_DETECTED_AFTER_CREATION',
    page:pageResult,worker:workerResult,service_worker:serviceWorkerResult,cors:corsResult,cors_counts:corsCounts,
    cancellation_proofs:cancellationProofs,canceled_transmitted:canceledTransmitted,guard:guard.snapshot()},null,2));
} catch {
  console.error(JSON.stringify({synthetic:'FAIL',forbidden_transmitted:forbiddenTransmitted,
    allowed_transmitted:allowedTransmitted,websocket_transmitted:websocketTransmitted,
    guard:guard?.snapshot()},null,2)); process.exitCode=1;
} finally {
  // Only this fixture's disposable process/profile are owned here.
  cdp?.socket.close(); browser.kill('SIGTERM');
  await Promise.race([once(browser,'exit'),new Promise(resolve=>setTimeout(resolve,3000))]);
  server.closeAllConnections(); await new Promise(resolve=>server.close(resolve));
  corsServer.closeAllConnections(); await new Promise(resolve=>corsServer.close(resolve));
  await rm(profile,{recursive:true,force:true});
}
