import assert from 'node:assert/strict';
import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';
import { createConnection } from 'node:net';

const dir = await mkdtemp(join(tmpdir(), 'splash-pi-question-test-'));
try {
  const source = await readFile('Sources/SplashFinish/Resources/Integrations/pi-questions.ts', 'utf8');
  const file = join(dir, 'questions.ts');
  await writeFile(file, source.replace('__EXECUTABLE_JSON__', JSON.stringify('/no/app')));
  const { registerQuestions, present } = await import(pathToFileURL(file).href);
  const previousDisabled = process.env.SPLASH_FINISH_DISABLED;
  process.env.SPLASH_FINISH_DISABLED = '1';
  registerQuestions({ on() { assert.fail('disabled worker must not register lifecycle hooks'); }, events: { on() { assert.fail('disabled worker must not subscribe to questions'); } } });
  if (previousDisabled === undefined) delete process.env.SPLASH_FINISH_DISABLED;
  else process.env.SPLASH_FINISH_DISABLED = previousDisabled;
  // Capture uses full inherited IDs. Invalid and remote coordinates are omitted.
  const rexKeys = ['REX_SESSION', 'REX_BLOCK', 'REX_SERVER', 'SSH_CONNECTION', 'SSH_TTY'];
  const rexPrevious = rexKeys.map(key => process.env[key]);
  try {
    const original = {session:'session:01a1d6be-ed97-7d65-b0bf-dbccd7256f1a', block:'block:01a1d9ff-f9a9-7831-b1e9-1187fcbf6756'};
    for (const [override, expected] of [[{}, original], [{REX_BLOCK:'block:short'}, undefined],
      [{REX_SESSION:original.session + '\n'}, undefined], [{REX_SERVER:'https://remote'}, undefined],
      [{SSH_CONNECTION:'remote'}, undefined], [{REX_BLOCK:''}, undefined]]) {
      rexKeys.forEach(key => delete process.env[key]);
      Object.assign(process.env, {REX_SESSION:original.session, REX_BLOCK:original.block}, override);
      const hooks = {}, subscribers = {}; let captured;
      registerQuestions({on(name, fn) {hooks[name] = fn;}, events:{on(name, fn) {subscribers[name] = fn;}}}, form => {
        captured = form; return {close() {}, result() {}};
      });
      hooks.session_start({}, {cwd:'/code/demo', sessionManager:{getSessionId:() => 'session'}});
      subscribers['pi-agent-ask:started']({version:1, flowId:'capture', questions:[
        {id:'q', label:'Q', prompt:'Choose', type:'single', options:[{value:'a', label:'A'}]}
      ]});
      assert.deepEqual(captured.rex, expected);
      hooks.session_shutdown();
    }
  } finally {
    rexKeys.forEach((key, index) => { if (rexPrevious[index] == null) delete process.env[key]; else process.env[key] = rexPrevious[index]; });
  }
  const handlers = {}, listeners = {}, forms = [];
  const events = { on(name, fn) { (listeners[name] ??= []).push(fn); }, emit(name, data) { for (const fn of listeners[name] ?? []) fn(data); } };
  registerQuestions({ on(name, fn) { handlers[name] = fn; }, events }, (form, submit) => {
    const item = { form, submit, closed: 0, results: [] }; forms.push(item);
    return { close() { item.closed++; }, result(ok, message) { item.results.push({ok,message}); } };
  });
  const ctx = { cwd: '/code/demo', sessionManager: { getSessionId: () => 'session' } };
  handlers.session_start({}, ctx);
  const questions = [
    {id:'one', label:'First', prompt:'Choose', type:'single', options:[{value:'1', label:'One'}, {value:'2', label:'Two'}]},
    {id:'two', label:'Second', prompt:'Choose more', type:'multi', options:[{value:'a',label:'A'}, {value:'b',label:'B'}]}
  ];
  const orcaEnv = ['ORCA_TERMINAL_HANDLE', 'ORCA_WORKTREE_ID', 'ORCA_PANE_KEY', 'REX_SESSION', 'REX_BLOCK', 'REX_SERVER', 'SSH_CONNECTION', 'SSH_TTY'];
  const previous = orcaEnv.map(key => process.env[key]);
  try {
    process.env.REX_SESSION = 'session:01a1d6be-ed97-7d65-b0bf-dbccd7256f1a';
    process.env.REX_BLOCK = 'block:01a1d9ff-f9a9-7831-b1e9-1187fcbf6756';
    delete process.env.REX_SERVER; delete process.env.SSH_CONNECTION; delete process.env.SSH_TTY;
    process.env.ORCA_TERMINAL_HANDLE = 'term_original';
    process.env.ORCA_WORKTREE_ID = 'repo-123::/tmp/Project With Spaces';
    process.env.ORCA_PANE_KEY = 'tab-1:leaf-1';
    events.emit('pi-agent-ask:started', {version:1, flowId:'flow-1', questions});
    assert.deepEqual(forms[0].form.rex, {session:process.env.REX_SESSION, block:process.env.REX_BLOCK});
    assert.deepEqual(forms[0].form.orca, {terminal:'term_original', worktree:'repo-123::/tmp/Project With Spaces', pane:'tab-1:leaf-1'});
  } finally {
    orcaEnv.forEach((key, i) => { if (previous[i] == null) delete process.env[key]; else process.env[key] = previous[i]; });
  }
  events.emit('pi-agent-ask:started', {version:1, flowId:'flow-2', questions});
  assert.equal(forms.length, 2); assert.equal(forms[0].form.session, 'session');
  const answer = {kind:'answer', answers:{one:{values:['2']},two:{values:['a','b'],note:'ok'}}};
  let sent;
  events.on('pi-agent-ask:submit', event => {
    sent = event;
    // The real package may emit completion before its submit-result acknowledgement.
    events.emit('pi-agent-ask:completed', {version:1, flowId:event.flowId});
    assert.equal(forms[0].closed, 0);
    events.emit('pi-agent-ask:submit-result', {version:1, flowId:event.flowId, requestId:event.requestId, ok:true});
  });
  forms[0].submit(answer);
  assert.deepEqual(sent.response, answer); assert.equal(forms[0].closed, 1);
  assert.equal(forms[0].results[0].ok, true); assert.equal(forms[1].closed, 0);
  events.emit('pi-agent-ask:completed', {version:1, flowId:'flow-2'});
  assert.equal(forms[1].closed, 1);
  events.emit('pi-agent-ask:started', {version:2, flowId:'unsupported', questions});
  assert.equal(forms.length, 2);
  handlers.session_shutdown();

  // Rejected and unrelated acknowledgements must not dismiss a live form.
  const retryHandlers = {}, retryListeners = {}, retryForms = [], sentRequests = [];
  const retryBus = { on(name, fn) { (retryListeners[name] ??= []).push(fn); }, emit(name, data) { for (const fn of retryListeners[name] ?? []) fn(data); } };
  registerQuestions({ on(name, fn) { retryHandlers[name] = fn; }, events: retryBus }, (f, submit) => {
    const item = { submit, closed: 0, results: [] }; retryForms.push(item);
    return {close() { item.closed++; }, result(ok, message) { item.results.push({ok,message}); }};
  });
  retryBus.on('pi-agent-ask:submit', request => sentRequests.push(request));
  retryHandlers.session_start({}, ctx);
  retryBus.emit('pi-agent-ask:started', {version:1, flowId:'retry', questions});
  retryForms[0].submit(answer); retryForms[0].submit(answer);
  assert.equal(sentRequests.length, 1, 'duplicate submit is suppressed while awaiting ack');
  retryBus.emit('pi-agent-ask:submit-result', {version:1, flowId:'retry', requestId:'wrong', ok:true});
  assert.equal(retryForms[0].closed, 0);
  retryBus.emit('pi-agent-ask:submit-result', {version:1, flowId:'retry', requestId:sentRequests[0].requestId, ok:false, error:'invalid_answer'});
  assert.equal(retryForms[0].results[0].ok, false); assert.equal(retryForms[0].closed, 0);
  retryForms[0].submit(answer); assert.equal(sentRequests.length, 2);
  retryBus.emit('pi-agent-ask:submit-result', {version:1, flowId:'retry', requestId:sentRequests[1].requestId, ok:true});
  assert.equal(retryForms[0].closed, 1);
  retryHandlers.session_shutdown();

  const form = {questions, project:'test', session:'s'};
  async function sendSocket(value) {
    let observed, socket;
    const closed = new Promise(resolve => {
      let transport;
      transport = present(form, result => { observed = result; transport.result(true); transport.close(); }, id => {
        socket = createConnection(`/tmp/sf-${process.getuid()}/${id}.sock`);
        let lines = '';
        socket.on('data', chunk => {
          lines += chunk.toString();
          if (lines.includes('\n') && !socket.sent) {
            socket.sent = true; assert.equal(JSON.parse(lines.split('\n')[0]).questions[0].id, 'one');
            socket.write(JSON.stringify(value) + '\n');
            // Invalid answers receive a negative acknowledgement and the terminal remains available.
            if (value.invalidTest) setTimeout(() => transport.close(), 40);
          }
        });
        socket.on('close', resolve);
      });
    });
    await closed; return observed;
  }
  assert.deepEqual(await sendSocket(answer), answer);
  assert.equal(await sendSocket({kind:'answer', answers:{one:{values:['not-offered']}}, invalidTest:true}), undefined);
  let invalidAck = false, acceptedAfterRetry = false;
  await new Promise(resolve => {
    let transport;
    transport = present(form, () => { acceptedAfterRetry = true; transport.result(true); transport.close(); }, id => {
      const socket = createConnection(`/tmp/sf-${process.getuid()}/${id}.sock`);
      let buffer = '';
      socket.on('data', chunk => {
        buffer += chunk.toString(); let n;
        while ((n = buffer.indexOf('\n')) >= 0) {
          const item = JSON.parse(buffer.slice(0,n)); buffer = buffer.slice(n+1);
          if (item.questions) socket.write(JSON.stringify({kind:'answer',answers:{one:{values:['invalid']}}})+'\n');
          else if (item.type === 'result' && !item.ok) { invalidAck = true; socket.write(JSON.stringify(answer)+'\n'); }
        }
      });
      socket.on('close', resolve);
    });
  });
  assert.equal(invalidAck, true); assert.equal(acceptedAfterRetry, true);
  console.log('PASS: pi-agent-ask lifecycle, concurrent forms, ack race, socket validation and fallback');
} finally { await rm(dir, {recursive:true,force:true}); }
