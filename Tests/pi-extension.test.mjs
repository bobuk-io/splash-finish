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
  const handlers = {};
  const calls = [];
  register({ on(name, handler) { handlers[name] = handler; } }, async notice => calls.push(notice));
  const ctx = { cwd: '/code/demo', sessionManager: { getSessionId: () => 'session-123' } };
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
  await handlers.ui_prompt_start({title: 'Pick a branch'}, child);
  assert.equal(calls.at(-1).status, 'attention');
  assert.equal(calls.at(-1).task, 'child-1');

  // Background subagents are detected through the environment instead of the session file.
  process.env.PI_SUBAGENT_CHILD = '1';
  try {
    const beforeEnvChild = calls.length;
    await handlers.before_agent_start({}, ctx);
    await handlers.agent_settled({aborted:false}, ctx);
    assert.equal(calls.length, beforeEnvChild, 'PI_SUBAGENT_CHILD lifecycle events are suppressed');
  } finally { delete process.env.PI_SUBAGENT_CHILD; }
  assert.ok(calls.length > 0);
  console.log('PASS: pi lifecycle, approval prompts, completion, error, abort, deduplication and subagent filtering');
} finally {
  await rm(temp, { recursive: true, force: true });
}
