// SPDX-License-Identifier: AGPL-3.0-or-later
import test from 'node:test';
import assert from 'node:assert/strict';
import {EventEmitter} from 'node:events';
import {classify, TransportGuard, protocolErrorReason} from './transport_guard.mjs';

const request = (path, method = 'PUT') => ({url: `https://synthetic.invalid${path}`, method});
const backupSession = () => ({first_message_index:0,forwarded_count:0,is_verified:false,
  session_data:{ephemeral:'ZmljdGlvbg',ciphertext:'ZmljdGlvbg',mac:'ZmljdGlvbg'}});
const backupBody = () => ({rooms:{'!fiction:local':{sessions:{fiction:backupSession()}}}});
const backupRequest = (body=backupBody(),path='/_matrix/client/v3/room_keys/keys?version=fiction',method='PUT') =>
  ({...request(path,method),postData:JSON.stringify(body)});
test('all public communication and account mutation routes fail closed', () => {
  for (const version of ['v3', 'r0', 'unstable']) {
    for (const method of ['POST', 'PUT', 'PATCH', 'DELETE']) {
      for (const route of [
        '/rooms/!fiction:local/send/m.room.message/txn',
        '/rooms/!fiction:local/send/m.room.encrypted/txn',
        '/rooms/!fiction:local/send/m.reaction/txn',
        '/rooms/!fiction:local/redact/$fiction/txn',
        '/rooms/!fiction:local/state/m.room.name',
        '/rooms/!fiction:local/receipt/m.read/$fiction',
        '/rooms/!fiction:local/read_markers', '/rooms/!fiction:local/typing/@fiction:local',
        '/presence/@fiction:local/status', '/join/!fiction:local',
        '/rooms/!fiction:local/join', '/rooms/!fiction:local/leave',
        '/user/@fiction:local/account_data/m.direct', '/profile/@fiction:local/displayname',
        '/devices/fiction', '/delete_devices', '/logout', '/login', '/register',
        '/pushers/set', '/keys/device_signing/upload',
      ]) assert.equal(classify(request(`/_matrix/client/${version}${route}`, method)).allow, false);
    }
  }
});
test('sync cannot implicitly promote presence; only one explicit offline is accepted', () => {
  for (const query of ['', '?set_presence=online', '?set_presence=unavailable', '?set_presence=offline&set_presence=online']) {
    assert.equal(classify(request('/_matrix/client/v3/sync' + query, 'GET')).allow, false);
  }
  assert.equal(classify(request('/_matrix/client/v3/sync?set_presence=offline', 'GET')).allow, true);
});
test('sync CORS preflight is allowed without weakening actual offline GET policy', () => {
  for (const query of ['', '?set_presence=offline', '?set_presence=online', '?set_presence=offline&set_presence=online']) {
    assert.deepEqual(classify(request('/_matrix/client/v3/sync' + query, 'OPTIONS')),
      {allow:true,code:'sync',reason:'options_preflight'});
  }
  for (const [query,reason] of [
    ['', 'presence_missing'], ['?set_presence=online', 'presence_non_offline'],
    ['?set_presence=offline&set_presence=offline', 'presence_multiple'],
  ]) assert.deepEqual(classify(request('/_matrix/client/v3/sync'+query,'GET')),{allow:false,code:'sync',reason});
  for(const method of ['HEAD','POST','PUT','PATCH','DELETE']) {
    assert.deepEqual(classify(request('/_matrix/client/v3/sync?set_presence=offline',method)),{allow:false,code:'sync',reason:'bad_method'});
  }
});
test('denied endpoint diagnostics use fixed codes without broadening permission', () => {
  const routes = [
    ['/user_directory/search','user_search'], ['/search','server_search'],
    ['/refresh','token_refresh'], ['/logout','logout'],
    ['/keys/signatures/upload','keys_signature'], ['/keys/device_signing/upload','keys_signing'],
    ['/room_keys/keys/fiction','keys_backup'], ['/room_keys/version','keys_backup_version'],
    ['/user/@fiction:local/account_data/fiction','account_data'],
    ['/user/@fiction:local/rooms/fiction/account_data/fiction','account_data'],
    ['/keys/fiction','keys_other'], ['/sendToDevice/fiction/txn','to_device_other'],
    ['/pushers/set','pusher_set'], ['/pushrules/global/fiction','push_rules'],
    ['/profile/fiction/displayname','profile'], ['/devices/fiction','devices'],
    ['/rooms/fiction/join','room_membership'], ['/fiction','other'],
  ];
  for (const [route,endpoint] of routes) {
    const result = classify(request('/_matrix/client/v3'+route,'POST'));
    assert.deepEqual(result,{allow:false,code:'account_or_other_matrix_write',endpoint,...(endpoint==='keys_backup'?{reason:'method'}:{})});
    assert.doesNotMatch(JSON.stringify(result), /fiction|@|\/|https/);
  }
});
test('existing encrypted backup permits only aggregate v3 PUT with one version query', () => {
  assert.deepEqual(classify(backupRequest()),{allow:true,code:'natural_crypto_backup'});
  assert.deepEqual(classify(backupRequest({rooms:{}})),{allow:true,code:'natural_crypto_backup'});
  for (const path of [
    '/_matrix/client/v3/room_keys/keys', '/_matrix/client/v3/room_keys/keys?version=',
    '/_matrix/client/v3/room_keys/keys?version=%20',
    '/_matrix/client/v3/room_keys/keys?version=fiction&version=fiction',
    '/_matrix/client/v3/room_keys/keys?version=fiction&extra=1',
    '/_matrix/client/v3/room_keys/keys?extra=fiction',
    '/_matrix/client/r0/room_keys/keys?version=fiction',
    '/_matrix/client/unstable/room_keys/keys?version=fiction',
    '/_matrix/client/v3/room_keys/keys/?version=fiction',
    '/_matrix/client/v3/room_keys/keys/fiction?version=fiction',
    '/_matrix/client/v3/room_keys/keys/fiction/fiction?version=fiction',
    '/_matrix/client/v3//room_keys/keys?version=fiction',
    '/proxy/_matrix/client/v3/room_keys/keys?version=fiction',
    '/_matrix/client/v3/room_keys/version',
    '/_matrix/client/v3/room_keys/version/fiction',
    '/_matrix/client/v3/keys/signatures/upload',
    '/_matrix/client/v3/keys/device_signing/upload',
    '/_matrix/client/v3/user/fiction/account_data/fiction',
  ]) assert.equal(classify(backupRequest(backupBody(),path)).allow,false,path);
  for(const method of ['POST','PATCH','DELETE']) assert.equal(classify(backupRequest(backupBody(),undefined,method)).allow,false);
});
test('backup envelope rejects plaintext, extra fields, malformed and oversized payloads', () => {
  const changes = [
    body=>{body.session_key='fiction';},
    body=>{body.rooms['!fiction:local'].session_key='fiction';},
    body=>{body.rooms['!fiction:local'].sessions.fiction.session_key='fiction';},
    body=>{body.rooms['!fiction:local'].sessions.fiction.session_data.session_key='fiction';},
    body=>{delete body.rooms['!fiction:local'].sessions.fiction.session_data.ciphertext;},
    body=>{body.rooms['!fiction:local'].sessions.fiction.session_data.ciphertext='clear text !';},
    body=>{body.rooms['!fiction:local'].sessions.fiction.session_data.mac='';},
    body=>{body.rooms['!fiction:local'].sessions.fiction.first_message_index=-1;},
    body=>{body.rooms['!fiction:local'].sessions.fiction.forwarded_count=0.5;},
    body=>{body.rooms['!fiction:local'].sessions.fiction.is_verified='false';},
    body=>{body.rooms['!fiction:local'].sessions.fiction.session_data=[];},
    body=>{body.rooms=[];},
  ];
  for(const change of changes) {
    const body=backupBody();change(body);
    const result=classify(backupRequest(body));assert.equal(result.allow,false);assert.equal(result.reason,'body_invalid_schema');
  }
  for(const body of [null,[],{}, {rooms:null}]) assert.equal(classify(backupRequest(body)).allow,false);
  for(const [postData,reason] of [[undefined,'body_unavailable'],['{','body_invalid_json'],[' '.repeat(1024*1024)+'{}','body_oversize']]) {
    const result=classify({...backupRequest(),postData});assert.equal(result.allow,false);assert.equal(result.reason,reason);
  }
  for(const postData of [
    '{"rooms":{"session_key":"fiction"},"rooms":{}}',
    JSON.stringify(backupBody()).replace('"session_data":{','"session_data":{"session_key":"fiction"},"session_data":{'),
    ' '+JSON.stringify(backupBody()),
  ]) {
    const result=classify({...backupRequest(),postData});assert.equal(result.allow,false);assert.equal(result.reason,'body_noncanonical_json');
  }
  const body=backupBody();body.rooms['!fiction:local'].sessions=Object.fromEntries(Array.from({length:50},(_,index)=>['fiction'+index,backupSession()]));
  assert.equal(classify(backupRequest(body)).allow,true);
  body.rooms['!fiction-two:local']={sessions:{fiction:backupSession()}};
  const result=classify(backupRequest(body));assert.equal(result.allow,false);assert.equal(result.reason,'body_session_limit');
});
test('approved natural sync filter permits only exact SDK v3 POST route', () => {
  for (const path of ['/_matrix/client/v3/user/@fiction:local/filter','/_matrix/client/v3/user/%40fiction%3Alocal/filter']) {
    assert.deepEqual(classify(request(path,'POST')),{allow:true,code:'natural_sync_filter'});
    for(const method of ['PUT','PATCH','DELETE']) assert.equal(classify(request(path,method)).allow,false);
  }
  for(const path of [
    '/_matrix/client/r0/user/@fiction:local/filter',
    '/_matrix/client/unstable/user/@fiction:local/filter',
    '/_matrix/client/v4/user/@fiction:local/filter',
    '/_matrix/client/v3/user/@fiction:local/filter/fiction',
    '/_matrix/client/v3/user/@fiction:local/filter/',
    '/_matrix/client/v3/user//filter',
    '/_matrix/client/v3//user/@fiction:local/filter',
    '//_matrix/client/v3/user/@fiction:local/filter',
    '/proxy/_matrix/client/v3/user/@fiction:local/filter',
    '/_matrix/client/v3/user/@fiction:local/filter?fiction=1',
    '/_matrix/client/v3/user/@fiction:local/account_data/fiction',
    '/_matrix/client/v3/user/@fiction:local/devices',
    '/_matrix/client/v3/devices/fiction',
  ]) assert.equal(classify(request(path,'POST')).allow,false,path);
  const denied=classify(request('/_matrix/client/r0/user/@fiction:local/filter','POST'));
  assert.equal(denied.endpoint,'filter_create');
});
test('natural keys and restricted to-device crypto remain separate from writes', () => {
  for (const operation of ['query', 'claim', 'upload']) assert.equal(classify(request('/_matrix/client/v3/keys/' + operation, 'POST')).allow, true);
  for (const type of ['m.room.encrypted', 'm.room_key_request', 'm.secret.request', 'm.secret.send']) {
    assert.equal(classify(request(`/_matrix/client/v3/sendToDevice/${type}/txn`)).allow, true);
  }
  assert.equal(classify(request('/_matrix/client/v3/sendToDevice/m.room.message/txn')).allow, false);
  assert.equal(classify(request('/_matrix/media/v3/upload', 'POST')).allow, false);
  assert.equal(classify(request('/unknown', 'POST')).allow, false);
  assert.equal(classify(request('/_matrix/client/v3/rooms/!fiction/messages', 'GET')).allow, true);
});
test('encoded operation cannot evade mutation guard; invalid inputs fail closed', () => {
  assert.equal(classify(request('/_matrix/client/v3/rooms/fiction/%73end/m.reaction/txn')).allow, false);
  for (const url of ['not a URL', 'https://synthetic.invalid/%xx', 'wss://synthetic.invalid/socket']) assert.equal(classify({url, method: 'GET'}).allow, false);
});
test('each target gets interception before resume and descendants auto-attach paused', async () => {
  class FakeCDP extends EventEmitter {
    calls = [];
    async send(method, params, sessionId) {this.calls.push({method, params, sessionId}); return {};}
  }
  const cdp = new FakeCDP(); const guard = new TransportGuard(cdp);
  for (const type of ['page', 'worker', 'service_worker', 'shared_worker', 'iframe']) {
    await guard.install(type, {type, targetId: type});
    const calls = cdp.calls.filter(call => call.sessionId === type);
    assert.ok(calls.findIndex(call => call.method === 'Fetch.enable') < calls.findIndex(call => call.method === 'Runtime.runIfWaitingForDebugger'));
    if (type !== 'service_worker') assert.equal(calls[0].params.waitForDebuggerOnStart, true);
    await guard.handle({method: 'Fetch.requestPaused', sessionId: type, params: {requestId: 'fiction', request: request('/_matrix/client/v3/rooms/fiction/send/m.room.message/txn')}});
    assert.equal(cdp.calls.at(-1).method, 'Fetch.failRequest');
  }
  assert.equal(guard.snapshot().blocked_attempts, 5);
  assert.equal(guard.snapshot().application, 'FAIL');
  assert.doesNotMatch(JSON.stringify(guard.snapshot()), /fiction|https|requestId|targetId/);
});
test('unexpected detach invalidates readiness and owner descendants until proven target death', async () => {
  class FakeCDP extends EventEmitter {async send() {return {};}}
  const guard = new TransportGuard(new FakeCDP());
  await guard.install('page',{type:'page',targetId:'fiction-page'});
  await guard.install('worker',{type:'worker',targetId:'fiction-worker'},'page');
  guard.sessions.get('worker').interception='owner_fetch'; guard.started=true;
  assert.equal(guard.isGuarded(),true);
  await guard.handle({method:'Target.detachedFromTarget',params:{sessionId:'page'}});
  assert.equal(guard.isGuarded(),false);
  assert.equal(guard.snapshot().unresolved_detaches,1);
  await guard.handle({method:'Target.targetDestroyed',params:{targetId:'fiction-page'}});
  assert.equal(guard.isGuarded(),false,'orphaned_worker_cannot_inherit_missing_parent');
});
test('failed Fetch commands remain sticky-unready and expose only fixed diagnostic stages', async () => {
  for (const [allow,path,stage] of [
    [false,'/user/@fiction:local/account_data/fiction','fetch_fail'],
    [true,'/sync?set_presence=offline','fetch_continue'],
  ]) {
    class FakeCDP extends EventEmitter {
      async send(method) {
        if(method === (allow ? 'Fetch.continueRequest' : 'Fetch.failRequest')) {
          const error = new Error('fictional private raw CDP error must never appear');
          error.code=-32000; throw error;
        }
        return {};
      }
    }
    const cdp = new FakeCDP(); const guard = new TransportGuard(cdp);
    await guard.install('page',{type:'page',targetId:'fiction'});guard.started=true;
    cdp.emit('event',{method:'Fetch.requestPaused',sessionId:'page',params:{requestId:'fiction',request:request('/_matrix/client/v3'+path,allow?'GET':'POST')}});
    await guard.settle();
    assert.equal(guard.snapshot().harness_errors,1);
    assert.equal(guard.isGuarded(),false);
    assert.equal(guard.counters[`command_failed:${stage}:server_error`],1);
    assert.equal(guard.counters['handler_failed:request_paused:server_error'],1);
    assert.equal(guard.snapshot().blocked_attempts,allow?0:1);
    assert.doesNotMatch(JSON.stringify(guard.snapshot()),/fiction|private|raw CDP|@/);
  }
});
test('only exact Chromium missing-interception error maps to cancellation candidate', () => {
  assert.equal(protocolErrorReason({code:-32602,message:'Invalid InterceptionId.'}),'interception_missing');
  for(const error of [{code:-32000,message:'Invalid InterceptionId.'},{code:-32602,message:'fictional private error'},
    {code:-32602,message:'Invalid InterceptionId. fictional data'},{code:-32602,message:'invalid interceptionid.'}]) {
    assert.equal(protocolErrorReason(error),'other');
  }
});
test('allowed continuation cancellation requires matching positive request proof', async () => {
  const cases = ['same_session','owner_worker','target_destroyed','not_canceled','wrong_request','unrelated_session','unknown_error'];
  for(const scenario of cases) {
    class FakeCDP extends EventEmitter {
      async send(method) {
        if(method==='Fetch.continueRequest') {
          const error=new Error('cdp_command_failed');error.code=-32602;
          error.protocolReason=scenario==='unknown_error'?'other':'interception_missing';throw error;
        }
        return {};
      }
    }
    const cdp=new FakeCDP();const guard=new TransportGuard(cdp);
    await guard.install('page',{type:'page',targetId:'fiction-page'});
    await guard.install('worker',{type:'worker',targetId:'fiction-worker'},'page');
    guard.sessions.get('worker').interception='owner_fetch';
    await guard.install('unrelated',{type:'page',targetId:'fiction-unrelated'});
    guard.started=true;
    const pauseSession=scenario==='target_destroyed'?'worker':'page';
    if(scenario==='owner_worker') await guard.handle({method:'Network.requestWillBeSent',sessionId:'worker',params:{requestId:'fiction-network'}});
    cdp.emit('event',{method:'Fetch.requestPaused',sessionId:pauseSession,params:{requestId:'fiction-fetch',networkId:'fiction-network',request:request('/_matrix/client/v3/sync?set_presence=offline','GET')}});
    await new Promise(resolve=>setTimeout(resolve,0));
    if(scenario!=='unknown_error') {
      assert.equal(guard.isGuarded(),false,'pending proof must invalidate readiness');
      assert.equal(guard.snapshot().pending_cancellation_checks,1);
    }
    if(scenario==='target_destroyed') {
      cdp.emit('event',{method:'Target.targetDestroyed',params:{targetId:'fiction-worker'}});
    } else {
      cdp.emit('event',{method:'Network.loadingFailed',sessionId:scenario==='owner_worker'?'worker':scenario==='unrelated_session'?'unrelated':'page',params:{requestId:scenario==='wrong_request'?'fiction-other':'fiction-network',canceled:scenario!=='not_canceled'}});
    }
    await guard.settle();
    const confirmed=['same_session','owner_worker','target_destroyed'].includes(scenario);
    assert.equal(guard.isGuarded(),confirmed,scenario);
    assert.equal(guard.snapshot().harness_errors,confirmed?0:1,scenario);
    assert.equal(guard.snapshot().confirmed_cancellations,confirmed?1:0,scenario);
    assert.equal(guard.snapshot().blocked_attempts,0);
    assert.doesNotMatch(JSON.stringify(guard.snapshot()),/fiction|https|requestId|targetId/);
  }
});
test('canceled forbidden attempt and failRequest error remain application FAIL and harness-unready', async () => {
  class FakeCDP extends EventEmitter {
    async send(method) {
      if(method==='Fetch.failRequest') {
        const error=new Error('cdp_command_failed');error.code=-32602;error.protocolReason='interception_missing';throw error;
      }
      return {};
    }
  }
  const cdp=new FakeCDP();const guard=new TransportGuard(cdp);
  await guard.install('page',{type:'page',targetId:'fiction-page'});guard.started=true;
  cdp.emit('event',{method:'Fetch.requestPaused',sessionId:'page',params:{requestId:'fiction-fetch',networkId:'fiction-network',request:request('/_matrix/client/v3/devices/fiction','POST')}});
  cdp.emit('event',{method:'Network.loadingFailed',sessionId:'page',params:{requestId:'fiction-network',canceled:true}});
  await guard.settle();
  assert.equal(guard.isGuarded(),false);assert.equal(guard.snapshot().harness_errors,1);
  assert.equal(guard.snapshot().application,'FAIL');assert.equal(guard.snapshot().blocked_attempts,1);
  assert.equal(guard.snapshot().confirmed_cancellations,0);
});
