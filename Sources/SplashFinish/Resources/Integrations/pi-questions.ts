// Managed by Splash Finish. Reinstall to update; uninstall-skills removes this file.
// Integrates only with pi-agent-ask's documented version 1 lifecycle/submit events.
import type { ExtensionAPI, ExtensionContext } from '@earendil-works/pi-coding-agent';
import { execFile } from 'node:child_process';
import { randomBytes } from 'node:crypto';
import { lstatSync, mkdirSync, unlinkSync } from 'node:fs';
import { createServer, type Server, type Socket } from 'node:net';
import { dirname, join } from 'node:path';

const executable: string = __EXECUTABLE_JSON__;
const maxBytes = 131072;
type Question = { id: string; label: string; prompt: string; context?: string; type: 'single' | 'multi'; options: { value: string; label: string; description?: string; recommended?: boolean }[] };
type OrcaSource = { terminal?: string; worktree?: string; pane?: string };
type Form = { title?: string; questions: Question[]; project: string; session: string; orca?: OrcaSource };
type Transport = { close(): void; result(ok: boolean, message?: string): void };

function normalize(event: any, ctx: ExtensionContext): Form | undefined {
    if (event?.version !== 1 || typeof event.flowId !== 'string' || !event.flowId || event.flowId.length > 512 || !Array.isArray(event.questions) || event.questions.length < 1 || event.questions.length > 20) return;
    if (event.title != null && (typeof event.title !== 'string' || event.title.length > 1000)) return;
    const ids = new Set<string>();
    for (const q of event.questions) {
        if (!q || typeof q.id !== 'string' || !q.id || q.id.length > 512 || ids.has(q.id) || typeof q.label !== 'string' || typeof q.prompt !== 'string' || q.prompt.length > 4000 || (q.context != null && (typeof q.context !== 'string' || q.context.length > 16000)) || !['single', 'multi'].includes(q.type) || !Array.isArray(q.options) || !q.options.length || q.options.length > 30) return;
        ids.add(q.id);
        const values = new Set<string>();
        for (const o of q.options) {
            if (!o || typeof o.value !== 'string' || !o.value || o.value.length > 512 || values.has(o.value) || typeof o.label !== 'string' || o.label.length > 1000 || (o.description != null && (typeof o.description !== 'string' || o.description.length > 4000))) return;
            values.add(o.value);
        }
    }
    const form: Form = { title: event.title, questions: event.questions.map((q: any) => ({ id: q.id, label: q.label, prompt: q.prompt, context: q.context, type: q.type, options: q.options.map((o: any) => ({ value: o.value, label: o.label, description: o.description, recommended: o.recommended === true })) })), project: ctx.cwd.split('/').pop() || '', session: ctx.sessionManager.getSessionId() };
    // Carry the original terminal, not the foreground project at the time of the click.
    const terminal = process.env.ORCA_TERMINAL_HANDLE;
    const worktree = process.env.ORCA_WORKTREE_ID ?? process.env.ORCA_WORKSPACE_ID;
    const pane = process.env.ORCA_PANE_KEY;
    if (terminal && /^term_[A-Za-z0-9_-]+$/.test(terminal) && terminal.length <= 128) {
        form.orca = { terminal };
        if (worktree && Buffer.byteLength(worktree) <= 2048 && !/[\x00-\x1f\x7f]/.test(worktree)) form.orca.worktree = worktree;
        if (pane && /^[A-Za-z0-9_-]+:[A-Za-z0-9_-]+$/.test(pane) && pane.length <= 256) form.orca.pane = pane;
    }
    if (Buffer.byteLength(JSON.stringify(form)) > maxBytes) return;
    return form;
}
function validResponse(form: Form, value: any): boolean {
    if (!value || value.kind !== 'answer' || !value.answers || typeof value.answers !== 'object' || Array.isArray(value.answers)) return false;
    return Object.entries(value.answers).every(([id, raw]: [string, any]) => {
        const q = form.questions.find(item => item.id === id);
        if (!q || !raw || typeof raw !== 'object' || Array.isArray(raw)) return false;
        const values = raw.values ?? [];
        if (!Array.isArray(values) || values.length > q.options.length || new Set(values).size !== values.length || values.some((v: unknown) => typeof v !== 'string' || !q.options.some(o => o.value === v))) return false;
        if (q.type === 'single' && (values.length > 1 || (values.length && typeof raw.customText === 'string' && raw.customText.trim()))) return false;
        if (raw.customText != null && (typeof raw.customText !== 'string' || raw.customText.length > 16000)) return false;
        if (raw.note != null && (typeof raw.note !== 'string' || raw.note.length > 16000)) return false;
        if (raw.optionNotes != null && (typeof raw.optionNotes !== 'object' || Array.isArray(raw.optionNotes) || !Object.entries(raw.optionNotes).every(([key, note]) => q.options.some(o => o.value === key) && typeof note === 'string' && note.length <= 16000))) return false;
        return true;
    });
}
function launchApp(id: string, failed: () => void): void {
    const app = dirname(dirname(dirname(executable)));
    if (!app.endsWith('.app')) return failed();
    execFile('/usr/bin/open', ['-g', '-a', app, `splash-finish://question?id=${id}`], { timeout: 3000 }, error => { if (error) failed(); });
}
export function present(form: Form, submit: (response: unknown) => void, launch = launchApp): Transport {
    let server: Server | undefined, client: Socket | undefined, timer: ReturnType<typeof setTimeout> | undefined;
    let socketPath = '', closed = false, buffer = '';
    const close = () => {
        if (closed) return; closed = true; if (timer) clearTimeout(timer);
        try { client?.end(JSON.stringify({ type: 'closed' }) + '\n'); } catch { try { client?.destroy(); } catch {} }
        try { server?.close(); } catch {}
        if (socketPath) { try { unlinkSync(socketPath); } catch {} }
    };
    const result = (ok: boolean, message?: string) => {
        if (!closed) client?.write(JSON.stringify({ type: 'result', ok, message }) + '\n');
    };
    try {
        if (typeof process.getuid !== 'function') return { close, result };
        const directory = `/tmp/sf-${process.getuid()}`;
        try { mkdirSync(directory, { mode: 0o700 }); } catch (error: any) { if (error.code !== 'EEXIST') throw error; }
        const stat = lstatSync(directory);
        if (!stat.isDirectory() || stat.isSymbolicLink() || stat.uid !== process.getuid() || (stat.mode & 0o077) !== 0) return { close, result };
        const id = randomBytes(16).toString('hex'); socketPath = join(directory, `${id}.sock`);
        server = createServer(socket => {
            if (client || closed) { socket.destroy(); return; }
            client = socket; if (timer) clearTimeout(timer);
            socket.write(JSON.stringify(form) + '\n');
            socket.setEncoding('utf8');
            socket.on('data', chunk => {
                buffer += chunk;
                if (Buffer.byteLength(buffer) > maxBytes) return close();
                let newline: number;
                while ((newline = buffer.indexOf('\n')) >= 0) {
                    const line = buffer.slice(0, newline); buffer = buffer.slice(newline + 1);
                    try {
                        const response = JSON.parse(line);
                        if (validResponse(form, response)) submit(response);
                        else result(false, 'Invalid answer. Review your choices or answer in pi.');
                    } catch { result(false, 'Invalid answer. Review your choices or answer in pi.'); }
                }
            });
            socket.on('error', close); socket.on('close', close);
        });
        server.on('error', close);
        server.listen(socketPath, () => { if (!closed) launch(id, close); });
        timer = setTimeout(close, 5000);
    } catch { close(); }
    return { close, result };
}

export function registerQuestions(pi: ExtensionAPI, presentForm = present): void {
    if (process.env.SPLASH_FINISH_DISABLED === '1') return;
    if (!pi.events?.on) return;
    let context: ExtensionContext | undefined;
    const flows = new Map<string, { transport: Transport; pending?: string; completed: boolean; timer?: ReturnType<typeof setTimeout> }>();
    const close = (id: string) => { const flow = flows.get(id); if (!flow) return; if (flow.timer) clearTimeout(flow.timer); flows.delete(id); flow.transport.close(); };
    pi.on('session_start', (_event, ctx) => { context = ctx; });
    pi.on('session_switch', (_event, ctx) => { for (const id of [...flows.keys()]) close(id); context = ctx; });
    pi.on('session_shutdown', () => { for (const id of [...flows.keys()]) close(id); context = undefined; });
    pi.events.on('pi-agent-ask:started', (event: any) => {
        try {
            if (!context || flows.size >= 32 || flows.has(event?.flowId)) return;
            const form = normalize(event, context); if (!form) return;
            const id: string = event.flowId;
            const transport = presentForm(form, response => {
                const flow = flows.get(id); if (!flow || flow.pending || flow.completed) return;
                const requestId = randomBytes(16).toString('hex'); flow.pending = requestId;
                flow.timer = setTimeout(() => { flow.transport.result(false, 'No confirmation from pi. Please answer in pi.'); close(id); }, 5000);
                pi.events.emit('pi-agent-ask:submit', { version: 1, requestId, flowId: id, response });
            });
            flows.set(id, { transport, completed: false });
        } catch { /* Keep the normal pi dialog usable. */ }
    });
    pi.events.on('pi-agent-ask:completed', (event: any) => {
        if (event?.version !== 1) return;
        const flow = flows.get(event.flowId); if (!flow) return;
        flow.completed = true;
        // Completion can be emitted synchronously before the submit acknowledgement.
        if (!flow.pending) close(event.flowId);
    });
    pi.events.on('pi-agent-ask:submit-result', (event: any) => {
        if (event?.version !== 1) return;
        const flow = flows.get(event.flowId);
        if (!flow || !flow.pending || flow.pending !== event.requestId || typeof event.ok !== 'boolean') return;
        if (flow.timer) clearTimeout(flow.timer); flow.timer = undefined; flow.pending = undefined;
        flow.transport.result(event.ok, event.ok ? undefined : 'Pi did not accept the answer. Review it or answer in pi.');
        if (event.ok || flow.completed || event.error === 'flow_not_found') close(event.flowId);
    });
}
export default function(pi: ExtensionAPI): void { registerQuestions(pi); }
