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

  // Selecta autonomous mode: globalThis[Symbol.for('pi-selecta.autonomy')], raw session id.
  const AUTONOMY = Symbol.for('pi-selecta.autonomy');
  const settleWith = async (state, stopReason = 'stop', target = ctx) => {
    if (state === undefined) delete globalThis[AUTONOMY]; else globalThis[AUTONOMY] = state;
    await handlers.before_agent_start({}, target);
    await handlers.message_end({message:{role:'assistant', content:[{type:'text', text:'Merged.'}], stopReason}}, target);
    const before = calls.length;
    await handlers.agent_settled({aborted:false}, target);
    return calls.slice(before);
  };
  const on = { version: 1, sessionId: 'session-123', on: true, by: '/selecta auto' };
  try {
    assert.deepEqual(await settleWith(on), [], 'autonomous completion is silent');
    assert.deepEqual(await settleWith(on, 'error'), [], 'autonomous generic error is silent');
    // Missing, malformed, other-version, other-session or off state keeps normal notices.
    for (const state of [undefined, null, 'on', 42, {}, { ...on, version: 2 }, { ...on, version: '1' },
      { ...on, on: 'true' }, { ...on, on: false }, { ...on, sessionId: 'other-session' },
      { ...on, sessionId: 'session_123' }, { ...on, sessionId: '' }, { ...on, sessionId: 123 }]) {
      const sent = await settleWith(state);
      assert.equal(sent.length, 1, `normal completion for ${JSON.stringify(state)}`);
      assert.equal(sent[0].status, 'done');
      assert.equal((await settleWith(state, 'error'))[0].status, 'attention');
    }
    // A throwing getter must not break the agent or hide the completion.
    const hostile = {}; Object.defineProperty(hostile, 'version', { get() { throw new Error('boom'); } });
    assert.equal((await settleWith(hostile))[0].status, 'done');

    // Actual questions still raise attention during an autonomous run.
    globalThis[AUTONOMY] = on;
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
    assert.equal((await settleWith({ ...on, on: false }))[0].status, 'done');

    // Late loading: an instance registered after the record exists, and a record that
    // appears after registration, are both read at settle time.
    globalThis[AUTONOMY] = on;
    const late = {}; const lateCalls = [];
    register({ on(name, handler) { late[name] = handler; } }, async notice => lateCalls.push(notice));
    await late.before_agent_start({}, ctx);
    await late.agent_settled({aborted:false}, ctx);
    assert.deepEqual(lateCalls.map(c => c.status), ['running']);
    delete globalThis[AUTONOMY];
    const early = {}; const earlyCalls = [];
    register({ on(name, handler) { early[name] = handler; } }, async notice => earlyCalls.push(notice));
    globalThis[AUTONOMY] = on;
    await early.before_agent_start({}, ctx);
    await early.agent_settled({aborted:false}, ctx);
    assert.deepEqual(earlyCalls.map(c => c.status), ['running']);
    // Session switch: the record names the old session, so the new session notifies.
    const switched = { cwd: '/code/demo', sessionManager: { getSessionId: () => 'session-456' } };
    const sent = await settleWith(on, 'stop', switched);
    assert.equal(sent[0].status, 'done');
    assert.equal(sent[0].task, 'session-456');
  } finally { delete globalThis[AUTONOMY]; }
  console.log('PASS: pi lifecycle, approval prompts, completion, error, abort, deduplication, subagent filtering and Selecta autonomy');
} finally {
  await rm(temp, { recursive: true, force: true });
}
