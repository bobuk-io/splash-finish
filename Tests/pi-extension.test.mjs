import assert from 'node:assert/strict';
import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';

const temp = await mkdtemp(join(tmpdir(), 'splash-finish-pi-'));
try {
  const source = await readFile('Sources/SplashFinish/Resources/Integrations/pi.ts', 'utf8');
  const file = join(temp, 'extension.ts');
  await writeFile(file, source.replace('__EXECUTABLE_JSON__', JSON.stringify('/no/such/binary')));
  const { register } = await import(pathToFileURL(file).href);
  const previousDisabled = process.env.SPLASH_FINISH_DISABLED;
  process.env.SPLASH_FINISH_DISABLED = '1';
  register({ on() { assert.fail('disabled worker must not register lifecycle hooks'); } });
  if (previousDisabled === undefined) delete process.env.SPLASH_FINISH_DISABLED;
  else process.env.SPLASH_FINISH_DISABLED = previousDisabled;
  const handlers = {};
  const calls = [];
  register({ on(name, handler) { handlers[name] = handler; } }, async notice => calls.push(notice));
  const ctx = { cwd: '/code/demo', sessionManager: { getSessionId: () => 'session-123' } };
  // User-opened settings menus (e.g. /jewter) must never notify or clear the inbox.
  for (const kind of ['custom', 'select', 'confirm', 'input', 'editor']) {
    await handlers.ui_prompt_start({kind, title: 'Jewter settings'}, ctx);
    await handlers.ui_prompt_end({}, ctx);
  }
  assert.equal(calls.length, 0, 'idle menus must not emit attention or running');
  await handlers.before_agent_start({}, ctx);
  assert.equal(calls.at(-1).status, 'running');
  const firstRun = calls.at(-1).run;
  assert.equal(calls.at(-1).sequence, 1);
  await handlers.ui_prompt_start({title: 'Approve migration?'}, ctx);
  assert.equal(calls.at(-1).status, 'attention');
  assert.equal(calls.at(-1).title, 'Approve migration?');
  assert.equal(calls.at(-1).sequence, 2);
  await handlers.ui_prompt_end({}, ctx);
  assert.equal(calls.at(-1).status, 'running');
  await handlers.tool_call({toolName:'ask_user'}, ctx);
  assert.equal(calls.at(-1).status, 'attention');
  await handlers.tool_execution_end({toolName:'ask_user'}, ctx);
  assert.equal(calls.at(-1).status, 'running');
  await handlers.message_end({message:{role:'assistant', content:[{type:'text', text:'All tests pass.'}], stopReason:'stop'}}, ctx);
  await handlers.agent_settled({aborted:false}, ctx);
  assert.equal(calls.at(-1).status, 'done');
  assert.equal(calls.at(-1).title, 'All tests pass.');
  assert.equal(calls.at(-1).task, 'session-123');
  assert.equal(calls.at(-1).project, 'demo');
  const count = calls.length;
  await handlers.ui_prompt_start({kind: 'custom'}, ctx);
  await handlers.ui_prompt_end({}, ctx);
  assert.equal(calls.length, count, 'idle menus must preserve the completed notification');
  await handlers.agent_settled({aborted:false}, ctx);
  assert.equal(calls.length, count, 'settled must not notify twice');
  await handlers.before_agent_start({}, ctx);
  assert.ok(calls.at(-1).run > firstRun);
  assert.equal(calls.at(-1).sequence, 1);
  await handlers.message_end({message:{role:'assistant', content:[], stopReason:'error'}}, ctx);
  await handlers.agent_settled({aborted:false}, ctx);
  assert.equal(calls.at(-1).status, 'attention');
  await handlers.before_agent_start({}, ctx);
  await handlers.agent_settled({aborted:true}, ctx);
  assert.equal(calls.at(-1).status, 'running');

  // Do not split Markdown destinations at the old 110-character boundary.
  const markdown = 'Готово: [0.3.4](https://example.com/' + 'a'.repeat(200) + ') опубликован.';
  await handlers.before_agent_start({}, ctx);
  await handlers.message_end({message:{role:'assistant', content:[{type:'text', text:markdown}], stopReason:'stop'}}, ctx);
  await handlers.agent_settled({aborted:false}, ctx);
  assert.equal(calls.at(-1).title, markdown);
  const longUnicode = 'ёж👨‍👩‍👧‍👦'.repeat(2000);
  await handlers.before_agent_start({}, ctx);
  await handlers.message_end({message:{role:'assistant', content:[{type:'text', text:longUnicode}], stopReason:'stop'}}, ctx);
  await handlers.agent_settled({aborted:false}, ctx);
  assert.ok(Buffer.byteLength(calls.at(-1).title, 'utf8') <= 4096);
  assert.ok(longUnicode.startsWith(calls.at(-1).title));
  assert.ok(!calls.at(-1).title.includes('\uFFFD'));

  // In-process subagents only report requests for input.
  const child = { cwd: '/code/demo', sessionManager: { getSessionId: () => 'child-1', getSessionFile: () => '/tmp/sessions/run-0/session.jsonl' } };
  const beforeChild = calls.length;
  await handlers.before_agent_start({}, child);
  await handlers.agent_settled({aborted:false}, child);
  assert.equal(calls.length, beforeChild, 'child lifecycle events are suppressed');
  await handlers.before_agent_start({}, child);
  await handlers.ui_prompt_start({title: 'Pick a branch'}, child);
  assert.equal(calls.at(-1).status, 'attention');
  assert.equal(calls.at(-1).task, 'child-1');
  await handlers.ui_prompt_end({}, child);
  await handlers.agent_settled({aborted:false}, child);

  // A late dialog-close event must not erase the final completion.
  await handlers.before_agent_start({}, ctx);
  await handlers.ui_prompt_start({title: 'Approve?'}, ctx);
  await handlers.agent_settled({aborted:false}, ctx);
  const afterSettled = calls.length;
  await handlers.ui_prompt_end({}, ctx);
  assert.equal(calls.length, afterSettled, 'late prompt end must not clear completion');

  // Background subagents are detected through the environment instead of the session file.
  process.env.PI_SUBAGENT_CHILD = '1';
  try {
    const beforeEnvChild = calls.length;
    await handlers.before_agent_start({}, ctx);
    await handlers.agent_settled({aborted:false}, ctx);
    assert.equal(calls.length, beforeEnvChild, 'PI_SUBAGENT_CHILD lifecycle events are suppressed');
  } finally { delete process.env.PI_SUBAGENT_CHILD; }
  assert.ok(calls.length > 0);

  // Selecta autonomous mode: globalThis[Symbol.for('pi-selecta.autonomy')] is a Map
  // from the raw Pi session id to { version: 1, sessionId, on, by }.
  const AUTONOMY = Symbol.for('pi-selecta.autonomy');
  const map = (...records) => new Map(records.map(r => [r.sessionId, r]));
  const settleWith = async (sessions, stopReason = 'stop', target = ctx) => {
    if (sessions === undefined) delete globalThis[AUTONOMY]; else globalThis[AUTONOMY] = sessions;
    await handlers.before_agent_start({}, target);
    await handlers.message_end({message:{role:'assistant', content:[{type:'text', text:'Merged.'}], stopReason}}, target);
    const before = calls.length;
    await handlers.agent_settled({aborted:false}, target);
    return calls.slice(before);
  };
  const on = { version: 1, sessionId: 'session-123', on: true, by: '/selecta auto' };
  const keyed = record => new Map([['session-123', record]]);
  try {
    assert.deepEqual(await settleWith(map(on)), [], 'autonomous completion is silent');
    assert.deepEqual(await settleWith(map(on), 'error'), [], 'autonomous generic error is silent');
    // Missing or malformed maps, and missing, malformed, other-version, mismatched or off
    // entries keep normal notices. A bare record (no map) and a plain object are malformed.
    for (const sessions of [undefined, null, 'on', 42, {}, on, { 'session-123': on }, new Map(),
      map({ ...on, sessionId: 'other-session' }), keyed(null), keyed('on'), keyed({}),
      keyed({ ...on, version: 2 }), keyed({ ...on, version: '1' }), keyed({ ...on, on: 'true' }),
      keyed({ ...on, on: false }), keyed({ ...on, sessionId: 'other-session' }),
      keyed({ ...on, sessionId: 'session_123' }), keyed({ ...on, sessionId: '' }), keyed({ ...on, sessionId: 123 })]) {
      const label = sessions instanceof Map ? JSON.stringify([...sessions]) : JSON.stringify(sessions);
      const sent = await settleWith(sessions);
      assert.equal(sent.length, 1, `normal completion for ${label}`);
      assert.equal(sent[0].status, 'done');
      assert.equal((await settleWith(sessions, 'error'))[0].status, 'attention');
    }
    // Throwing getters must not break the agent or hide the completion.
    const hostile = {}; Object.defineProperty(hostile, 'version', { get() { throw new Error('boom'); } });
    assert.equal((await settleWith(keyed(hostile)))[0].status, 'done');
    class HostileMap extends Map { get() { throw new Error('boom'); } }
    assert.equal((await settleWith(new HostileMap([['session-123', on]])))[0].status, 'done');

    // Parent and in-process child sessions publish separate entries in one process.
    // A child entry, or its removal, never changes the parent's mode.
    const other = { cwd: '/code/demo', sessionManager: { getSessionId: () => 'session-456' } };
    const shared = map(on, { version: 1, sessionId: 'session-456', on: false, by: 'default' });
    assert.deepEqual(await settleWith(shared), [], 'parent stays autonomous beside a child entry');
    assert.equal((await settleWith(shared, 'stop', other))[0].status, 'done', 'the other session notifies');
    shared.delete('session-456');
    assert.deepEqual(await settleWith(shared), [], 'child removal keeps parent autonomy');
    shared.set('session-456', { version: 1, sessionId: 'session-456', on: true, by: 'dashboard' });
    shared.set('session-123', { ...on, on: false });
    assert.deepEqual(await settleWith(shared, 'stop', other), [], 'the other session is autonomous');
    assert.equal((await settleWith(shared))[0].status, 'done', 'the parent is not');

    // Actual questions still raise attention during an autonomous run.
    globalThis[AUTONOMY] = map(on);
    await handlers.before_agent_start({}, ctx);
    await handlers.ui_prompt_start({title: 'Approve resume?'}, ctx);
    assert.equal(calls.at(-1).status, 'attention');
    assert.equal(calls.at(-1).title, 'Approve resume?');
    await handlers.ui_prompt_end({}, ctx);
    assert.equal(calls.at(-1).status, 'running');
    await handlers.tool_call({toolName:'ask_user'}, ctx);
    assert.equal(calls.at(-1).status, 'attention');
    await handlers.tool_execution_end({toolName:'ask_user'}, ctx);
    // A question still open at settle is preserved; its own close clears it later.
    await handlers.ui_prompt_start({title: 'Pick a branch'}, ctx);
    const open = calls.length;
    await handlers.agent_settled({aborted:false}, ctx);
    assert.equal(calls.length, open, 'settle keeps the open question');
    assert.equal(calls.at(-1).status, 'attention');
    await handlers.ui_prompt_end({}, ctx);
    assert.equal(calls.at(-1).status, 'running', 'the answered question is cleared');
    const closed = calls.length;
    await handlers.ui_prompt_end({}, ctx);
    assert.equal(calls.length, closed, 'clear only once');
    // An abort still clears the running entry.
    await handlers.before_agent_start({}, ctx);
    await handlers.agent_settled({aborted:true}, ctx);
    assert.equal(calls.at(-1).status, 'running');
    // Idle menus stay quiet in autonomous mode too.
    const idle = calls.length;
    await handlers.ui_prompt_start({kind: 'select'}, ctx);
    await handlers.ui_prompt_end({}, ctx);
    assert.equal(calls.length, idle);
    // Autonomy turned off mid-session: the next completion is normal again.
    assert.equal((await settleWith(map({ ...on, on: false })))[0].status, 'done');

    // Late loading: an instance registered after the record exists, and a record that
    // appears after registration, are both read at settle time.
    globalThis[AUTONOMY] = map(on);
    const late = {}; const lateCalls = [];
    register({ on(name, handler) { late[name] = handler; } }, async notice => lateCalls.push(notice));
    await late.before_agent_start({}, ctx);
    await late.agent_settled({aborted:false}, ctx);
    assert.deepEqual(lateCalls.map(c => c.status), ['running']);
    delete globalThis[AUTONOMY];
    const early = {}; const earlyCalls = [];
    register({ on(name, handler) { early[name] = handler; } }, async notice => earlyCalls.push(notice));
    globalThis[AUTONOMY] = map(on);
    await early.before_agent_start({}, ctx);
    await early.agent_settled({aborted:false}, ctx);
    assert.deepEqual(earlyCalls.map(c => c.status), ['running']);
    // Session switch: the record names the old session, so the new session notifies.
    const switched = { cwd: '/code/demo', sessionManager: { getSessionId: () => 'session-456' } };
    const sent = await settleWith(map(on), 'stop', switched);
    assert.equal(sent[0].status, 'done');
    assert.equal(sent[0].task, 'session-456');
  } finally { delete globalThis[AUTONOMY]; }
  console.log('PASS: pi lifecycle, approval prompts, completion, error, abort, deduplication, subagent filtering and Selecta autonomy');
} finally {
  await rm(temp, { recursive: true, force: true });
}
