import assert from 'node:assert/strict';
import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';

const temp = await mkdtemp(join(tmpdir(), 'splash-finish-omp-'));
const previousDisabled = process.env.SPLASH_FINISH_DISABLED;
const realNow = Date.now;
try {
  delete process.env.SPLASH_FINISH_DISABLED;
  const source = await readFile('Sources/SplashFinish/Resources/Integrations/omp.ts', 'utf8');
  const file = join(temp, 'extension.ts');
  const executable = '/not installed/Splash Finish.app/Contents/MacOS/splash-finish';
  await writeFile(file, source.replace('__EXECUTABLE_JSON__', JSON.stringify(executable)));
  const { default: splashFinish } = await import(pathToFileURL(file).href);
  const privateText = 'SYNTHETIC_PRIVATE_TEXT';
  const messages = [{ role: 'assistant', stopReason: 'stop', content: [{ type: 'text', text: privateText }] }];
  const emptyJobs = () => ({ running: [], delivery: { queued: 0, delivering: false, pendingJobIds: [] } });

  function harness() {
    const handlers = new Map();
    const timers = new Map();
    const notices = [];
    const state = {
      id: 'session-123', kind: 'main', mode: 'tui', idle: true, pending: false, jobs: emptyJobs(),
      deliver: () => Promise.resolve({ code: 0 }),
    };
    const ctx = {
      cwd: `/work/${privateText}/demo`,
      get agent() { return { kind: state.kind }; },
      get mode() { return state.mode; },
      sessionManager: { getSessionId: () => state.id },
      isIdle: () => state.idle,
      hasPendingMessages: () => state.pending,
      getAsyncJobSnapshot: () => state.jobs,
      setTimeout(callback, delay) {
        const handle = Symbol();
        timers.set(handle, { callback, delay });
        return handle;
      },
      clearTimer(handle) { timers.delete(handle); },
    };
    splashFinish({
      on(event, handler) {
        assert.ok(!handlers.has(event), `duplicate hook: ${event}`);
        handlers.set(event, handler);
      },
      exec(command, args, options) {
        notices.push({ command, args, options });
        return state.deliver();
      },
    });
    return {
      notices, state,
      get statuses() { return notices.map(({ args }) => args[args.indexOf('--status') + 1]); },
      get timerCount() { return timers.size; },
      emit(type, payload = {}) {
        assert.ok(handlers.has(type), `missing hook: ${type}`);
        assert.equal(handlers.get(type)({ type, ...payload }, ctx), undefined, `observer must not return a decision: ${type}`);
      },
      takeTimer(delay = 0) {
        assert.equal(timers.size, 1, 'expected exactly one settle timer');
        const [handle, timer] = timers.entries().next().value;
        assert.equal(timer.delay, delay);
        timers.delete(handle);
        return timer.callback;
      },
    };
  }

  function fields({ command, args, options }) {
    assert.equal(command, executable);
    assert.deepEqual(options, { timeout: 1000 });
    assert.equal(args[0], 'notify');
    assert.equal(args.length, 17);
    const flags = {};
    for (let i = 1; i < args.length; i += 2) flags[args[i]] = args[i + 1];
    assert.deepEqual(Object.keys(flags).sort(), [
      '--agent', '--detail', '--project', '--run', '--sequence', '--status', '--task', '--title',
    ]);
    assert.equal(flags['--agent'], 'OMP');
    assert.equal(flags['--project'], 'demo');
    assert.match(flags['--title'], /OMP/);
    assert.ok(flags['--detail']);
    assert.ok(!args.some(arg => arg.includes(privateText)), 'only safe session metadata may reach the CLI');
    return { task: flags['--task'], run: Number(flags['--run']), sequence: Number(flags['--sequence']) };
  }

  // A session owns one stable task ID and ordered update stream, even across turns.
  Date.now = () => 123456789;
  try {
    const h = harness();
    h.emit('session_start');
    assert.deepEqual(h.statuses, []);
    h.emit('agent_start');
    h.emit('agent_end', { messages: [{ role: 'assistant', stopReason: 'error' }, ...messages] });
    assert.deepEqual(h.statuses, ['running'], 'settle must not publish in the agent_end handler');
    h.takeTimer()();
    h.emit('input', { text: privateText });
    h.emit('agent_start');
    h.emit('agent_end', { messages });
    h.takeTimer()();
    assert.deepEqual(h.statuses, ['running', 'done', 'running', 'running', 'done']);
    assert.deepEqual(h.notices.map(fields), [1, 2, 3, 4, 5].map(sequence => ({
      task: h.state.id, run: 123456789, sequence,
    })));

    // Rebinding orders both another session and a later return to the same task,
    // even when Date.now() never advances.
    for (const [id, run] of [['session-456', 123456790], ['session-123', 123456791], ['session-123', 123456792]]) {
      h.emit('agent_end', { messages });
      const stale = h.takeTimer();
      h.state.id = id;
      h.emit('session_switch');
      h.emit('agent_start');
      h.emit('agent_end', { messages });
      const count = h.notices.length;
      stale();
      assert.equal(h.notices.length, count);
      assert.deepEqual(fields(h.notices.at(-1)), { task: id, run, sequence: 1 });
      h.takeTimer()();
      assert.deepEqual(fields(h.notices.at(-1)), { task: id, run, sequence: 2 });
    }
  } finally { Date.now = realNow; }

  for (const stopReason of ['error', 'aborted']) {
    const h = harness();
    h.emit('agent_start');
    h.emit('agent_end', { messages: [...messages, { role: 'assistant', stopReason, errorMessage: privateText }, { role: 'toolResult' }] });
    h.takeTimer()();
    assert.deepEqual(h.statuses, ['running', 'attention'], `${stopReason} is not a completion`);
    h.notices.forEach(fields);
  }

  for (const flags of [{ willContinue: true }, { awaitingAsyncWork: true }, { willContinue: true, awaitingAsyncWork: true }]) {
    const h = harness();
    h.emit('agent_start');
    h.emit('agent_end', { messages });
    const stale = h.takeTimer();
    h.emit('agent_end', { messages, ...flags });
    stale();
    assert.deepEqual(h.statuses, ['running'], 'continuation must suppress a pending completion');
    assert.equal(h.timerCount, 0);
    h.emit('agent_end', { messages });
    h.takeTimer()();
    assert.deepEqual(h.statuses, ['running', 'done']);
  }

  for (const [label, block] of [
    ['busy agent', state => { state.idle = false; }],
    ['queued messages', state => { state.pending = true; }],
    ['running job', state => state.jobs.running.push({ id: 'job' })],
    ['queued job delivery', state => { state.jobs.delivery.queued = 1; }],
    ['active job delivery', state => { state.jobs.delivery.delivering = true; }],
    ['pending job result', state => state.jobs.delivery.pendingJobIds.push('job')],
  ]) {
    const h = harness();
    h.emit('agent_end', { messages });
    block(h.state); // Work can arrive between agent_end and the next tick.
    h.takeTimer()();
    assert.deepEqual(h.statuses, [], `completion must wait for ${label}`);
    h.takeTimer(250)();
    assert.deepEqual(h.statuses, []);
    Object.assign(h.state, { idle: true, pending: false, jobs: null });
    h.takeTimer(250)();
    assert.deepEqual(h.statuses, ['done'], 'an absent async job manager does not block completion');
  }

  {
    const h = harness();
    const ask = { toolName: 'ask', toolCallId: 'shared', input: { html: privateText } };
    const secondAsk = { ...ask, toolCallId: 'second' };
    const approval = { sessionId: h.state.id, toolCallId: 'shared', reason: privateText };
    const review = { sessionId: h.state.id, reviewId: 'shared', title: privateText, planContent: privateText };
    h.emit('agent_start');
    h.emit('tool_call', { toolName: 'eval', toolCallId: 'outer' });
    h.emit('tool_approval_requested', { ...approval, sessionId: 'previous-session' });
    h.emit('plan_review_requested', { ...review, sessionId: 'previous-session' });
    assert.deepEqual(h.statuses, ['running']);

    h.emit('tool_call', ask);
    h.emit('tool_call', secondAsk);
    h.emit('tool_approval_requested', approval);
    h.emit('plan_review_requested', review);
    assert.deepEqual(h.statuses, ['running', ...Array(4).fill('attention')]);
    const count = h.notices.length;
    h.emit('tool_call', ask);
    h.emit('tool_approval_requested', approval);
    h.emit('plan_review_requested', review);
    h.emit('tool_result', { ...secondAsk, toolName: 'write' });
    h.emit('tool_result', { ...ask, toolCallId: 'unknown' });
    h.emit('tool_approval_resolved', { ...approval, sessionId: 'previous-session', approved: true });
    h.emit('plan_review_resolved', { ...review, sessionId: 'previous-session' });
    assert.equal(h.notices.length, count, 'duplicate, unmatched, and foreign events do not change the inbox');
    h.emit('input', { text: privateText });
    assert.equal(h.statuses.at(-1), 'attention', 'new work cannot clear a still-open question');

    h.emit('agent_end', { messages });
    h.takeTimer()();
    for (const [name, event] of [
      ['tool_result', { ...ask, content: privateText }],
      ['tool_approval_resolved', { ...approval, approved: false }],
      ['plan_review_resolved', { ...review, choice: undefined, by: 'local' }],
    ]) {
      h.emit(name, event);
      h.takeTimer(250)();
      assert.equal(h.statuses.at(-1), 'attention', 'only the last answer clears attention');
    }
    h.emit('tool_result', { ...secondAsk, content: privateText });
    assert.equal(h.statuses.at(-1), 'running');
    h.takeTimer(250)();
    assert.equal(h.statuses.at(-1), 'done');
    h.emit('tool_result', secondAsk);
    h.emit('tool_approval_resolved', approval);
    h.emit('plan_review_resolved', review);
    assert.deepEqual(h.statuses.slice(-2), ['running', 'done'], 'a late result must not erase completion');
    h.notices.forEach(fields);
  }

  for (const event of ['input', 'agent_start']) {
    const h = harness();
    h.emit('agent_end', { messages });
    const stale = h.takeTimer();
    h.emit(event);
    h.emit('agent_end', { messages });
    stale();
    assert.deepEqual(h.statuses, ['running'], `${event} invalidates the preceding settle`);
    h.takeTimer()();
    assert.deepEqual(h.statuses, ['running', 'done']);
  }

  {
    const h = harness();
    h.emit('agent_end', { messages });
    const stale = h.takeTimer();
    h.state.id = 'session-456'; // The session manager can change before session_switch is emitted.
    stale();
    assert.deepEqual(h.statuses, [], 'a pending completion cannot cross session identities');
    assert.equal(h.timerCount, 0);
  }

  for (const guardedState of [{ kind: 'sub' }, { mode: 'print' }, { mode: 'json' }, { mode: 'rpc' }, { mode: 'acp' }, 'disabled']) {
    const h = harness();
    const delayed = harness();
    delayed.emit('agent_end', { messages });
    const callback = delayed.takeTimer();
    if (guardedState === 'disabled') process.env.SPLASH_FINISH_DISABLED = '1';
    else {
      Object.assign(h.state, guardedState);
      Object.assign(delayed.state, guardedState);
    }
    try {
      h.emit('session_start');
      h.emit('input');
      h.emit('agent_start');
      h.emit('tool_call', { toolName: 'ask', toolCallId: 'ask' });
      h.emit('tool_approval_requested', { sessionId: h.state.id, toolCallId: 'approval' });
      h.emit('plan_review_requested', { sessionId: h.state.id, reviewId: 'review' });
      h.emit('agent_end', { messages });
      assert.deepEqual(h.statuses, []);
      assert.equal(h.timerCount, 0);
      callback();
      assert.deepEqual(delayed.statuses, [], 'deferred delivery must recheck its guard');
      assert.equal(delayed.timerCount, 0);
    } finally { delete process.env.SPLASH_FINISH_DISABLED; }
  }

  {
    const completed = harness();
    completed.emit('agent_end', { messages });
    completed.takeTimer()();
    completed.emit('session_shutdown');
    completed.emit('tool_call', { toolName: 'ask', toolCallId: 'late' });
    assert.deepEqual(completed.statuses, ['done'], 'shutdown preserves the completed card');

    const pending = harness();
    pending.emit('agent_end', { messages });
    const stale = pending.takeTimer();
    pending.emit('agent_end', { messages });
    process.env.SPLASH_FINISH_DISABLED = '1';
    try { pending.emit('session_shutdown'); }
    finally { delete process.env.SPLASH_FINISH_DISABLED; }
    assert.equal(pending.timerCount, 0);
    stale();
    assert.deepEqual(pending.statuses, []);
  }

  {
    const previous = harness();
    const next = harness();
    previous.emit('tool_call', { toolName: 'ask', toolCallId: 'prompt' });
    next.emit('agent_end', { messages });
    next.takeTimer()();
    assert.deepEqual(previous.statuses, ['attention']);
    assert.deepEqual(next.statuses, ['done'], 'one extension instance cannot block another');
  }

  const unavailable = new Error('Synthetic delivery failure');
  for (const deliver of [() => { throw unavailable; }, () => Promise.reject(unavailable), () => Promise.resolve({ code: 1 })]) {
    const h = harness();
    h.state.deliver = deliver;
    h.emit('agent_start');
    h.emit('agent_end', { messages });
    h.takeTimer()();
    await Promise.resolve();
    assert.deepEqual(h.statuses, ['running', 'done'], 'delivery failure must not block OMP or retry');
  }

  console.log('PASS: OMP lifecycle, async settling, session ordering, passive attention, privacy, and delivery guards');
} finally {
  if (previousDisabled === undefined) delete process.env.SPLASH_FINISH_DISABLED;
  else process.env.SPLASH_FINISH_DISABLED = previousDisabled;
  await rm(temp, { recursive: true, force: true });
}
