// Managed by Splash Finish. Opens one Orca structured-chat session using Orca's
// own bundled runtime client, so this never reimplements Orca's wire protocol.
// reveal publishes and activates the chat tab; worktree.activate brings that
// workspace on screen, because the tab alone can stay behind the visible one.
// Arguments: <runtime-client-path> <session-id>. Prints the RPC replies as JSON lines.
const [clientPath, sessionId] = process.argv.slice(2);
if (!clientPath || !sessionId) {
  process.stderr.write('usage: reveal-agent-session <runtime-client.js> <session-id>\n');
  process.exit(2);
}
const { RuntimeClient } = require(clientPath);
const write = value => process.stdout.write(JSON.stringify(value) + '\n');
const client = new RuntimeClient();
client
  .call('agentSession.reveal', { sessionId })
  .then(reply => {
    write(reply);
    const workspace = reply && reply.result && reply.result.workspaceId;
    const revealed = reply && reply.ok === true && reply.result && reply.result.ok === true &&
      typeof workspace === 'string' && workspace.length > 0;
    if (!revealed) { process.exit(1); }
    return client.call('worktree.activate', { worktree: workspace }).then(activated => {
      write(activated);
      const applied = activated && activated.ok === true && activated.result &&
        activated.result.activated === true && activated.result.worktreeId === workspace;
      process.exit(applied ? 0 : 1);
    });
  })
  .catch(error => { process.stderr.write(String((error && error.message) || error)); process.exit(1); });
