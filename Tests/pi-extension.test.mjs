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
  await handlers.ui_prompt_start({title: 'Approve migration?'}, ctx);
  assert.equal(calls.at(-1).status, 'attention');
  assert.equal(calls.at(-1).title, 'Approve migration?');
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
  await handlers.message_end({message:{role:'assistant', content:[], stopReason:'error'}}, ctx);
  await handlers.agent_settled({aborted:false}, ctx);
  assert.equal(calls.at(-1).status, 'attention');
  await handlers.before_agent_start({}, ctx);
  await handlers.agent_settled({aborted:true}, ctx);
  assert.equal(calls.at(-1).status, 'running');
  console.log('PASS: pi lifecycle, approval prompts, completion, error, abort and deduplication');
} finally {
  await rm(temp, { recursive: true, force: true });
}
