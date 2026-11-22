// Managed by Splash Finish (OMP). Reinstall to update; uninstall-skills removes this file.
import type { ExtensionAPI, ExtensionContext } from "@oh-my-pi/pi-coding-agent";
import { basename } from "node:path";

type Status = "running" | "done" | "attention";
type Binding = {
    id: string;
    run: number;
    sequence: number;
    revision: number;
    closed: boolean;
    waiting: Set<string>;
    timer?: { ctx: ExtensionContext; handle: Timer };
};

// Never forward prompts, answers, transcripts, error messages, or plan contents.
const messages = {
    running: { title: "OMP is working", detail: "Work is continuing in OMP." },
    done: { title: "OMP work completed", detail: "The result is available in OMP." },
    attention: { title: "OMP needs attention", detail: "Check OMP for a question, approval, plan review, or interrupted work." },
};

export default function splashFinish(pi: ExtensionAPI): void {
    // The installer injects the absolute bundled binary path. No shell, no PATH dependency.
    const executable: string = __EXECUTABLE_JSON__;
    let binding: Binding | undefined;
    let lastRun = 0;

    function sessionId(ctx: ExtensionContext): string | undefined {
        if (ctx.agent.kind === "main" && ctx.mode === "tui") return ctx.sessionManager.getSessionId();
    }

    function cancelSettle(state: Binding): void {
        state.revision++;
        if (state.timer) {
            state.timer.ctx.clearTimer(state.timer.handle);
            state.timer = undefined;
        }
    }

    function current(ctx: ExtensionContext, reset = false, expectedSessionId?: string): Binding | undefined {
        if (!reset && process.env.SPLASH_FINISH_DISABLED === "1") return;
        const id = sessionId(ctx);
        if (id === undefined || (expectedSessionId !== undefined && expectedSessionId !== id)) return;
        if (reset || !binding || binding.id !== id) {
            if (binding) cancelSettle(binding);
            lastRun = Math.max(Date.now(), lastRun + 1);
            binding = { id, run: lastRun, sequence: 0, revision: 0, closed: false, waiting: new Set() };
        }
        return binding.closed ? undefined : binding;
    }

    function notify(ctx: ExtensionContext, state: Binding, status: Status): void {
        const { title, detail } = messages[status];
        const args = ["notify", "--agent", "OMP", "--task", state.id,
            "--run", String(state.run), "--sequence", String(++state.sequence),
            "--status", status, "--project", basename(ctx.cwd), "--title", title, "--detail", detail];
        // Delivery never holds up OMP. The inbox rejects out-of-order updates by run and sequence.
        try {
            void pi.exec(executable, args, { timeout: 1000 }).catch(() => {});
        } catch { /* Notifications must never interrupt the agent. */ }
    }

    function running(_event: unknown, ctx: ExtensionContext): void {
        const state = current(ctx);
        if (!state) return;
        cancelSettle(state);
        notify(ctx, state, state.waiting.size ? "attention" : "running");
    }

    function waiting(ctx: ExtensionContext, key: string, pending: boolean, expectedSessionId?: string): void {
        const state = current(ctx, false, expectedSessionId);
        if (!state) return;
        if (pending) {
            if (state.waiting.has(key)) return;
            state.waiting.add(key);
        } else if (!state.waiting.delete(key)) {
            return;
        }
        notify(ctx, state, state.waiting.size ? "attention" : "running");
    }

    pi.on("session_start", (_event, ctx) => { current(ctx, true); });
    pi.on("session_switch", (_event, ctx) => { current(ctx, true); });
    pi.on("agent_start", running);
    pi.on("input", running);

    pi.on("agent_end", (event, ctx) => {
        const state = current(ctx);
        if (!state) return;
        cancelSettle(state);
        if (event.willContinue || event.awaitingAsyncWork) return;
        const stopReason = event.messages.findLast(message => message.role === "assistant")?.stopReason;
        const status = stopReason === "error" || stopReason === "aborted" ? "attention" : "done";
        const revision = state.revision;
        // The loop can emit agent_end before OMP has drained the prompt and async job queues.
        const check = (): void => {
            if (binding !== state || state.revision !== revision) return;
            state.timer = undefined;
            if (process.env.SPLASH_FINISH_DISABLED === "1" || sessionId(ctx) !== state.id) return;
            const jobs = ctx.getAsyncJobSnapshot();
            if (state.waiting.size || !ctx.isIdle() || ctx.hasPendingMessages()
                || (jobs && (jobs.running.length || jobs.delivery.queued || jobs.delivery.delivering
                    || jobs.delivery.pendingJobIds.length))) {
                state.timer = { ctx, handle: ctx.setTimeout(check, 250) };
                return;
            }
            notify(ctx, state, status);
        };
        state.timer = { ctx, handle: ctx.setTimeout(check, 0) };
    });

    // Nested asks through eval and xd://ask also emit tool_call and tool_result.
    pi.on("tool_call", (event, ctx) => {
        if (event.toolName === "ask") waiting(ctx, `ask:${event.toolCallId}`, true);
    });
    pi.on("tool_result", (event, ctx) => {
        if (event.toolName === "ask") waiting(ctx, `ask:${event.toolCallId}`, false);
    });
    pi.on("tool_approval_requested", (event, ctx) => {
        waiting(ctx, `approval:${event.toolCallId}`, true, event.sessionId);
    });
    pi.on("tool_approval_resolved", (event, ctx) => {
        waiting(ctx, `approval:${event.toolCallId}`, false, event.sessionId);
    });
    pi.on("plan_review_requested", (event, ctx) => {
        waiting(ctx, `review:${event.reviewId}`, true, event.sessionId);
    });
    pi.on("plan_review_resolved", (event, ctx) => {
        waiting(ctx, `review:${event.reviewId}`, false, event.sessionId);
    });
    pi.on("session_shutdown", (_event, ctx) => {
        // Even if disabled mid-session, stop the timer without clearing a delivered notice.
        if (!binding || binding.id !== sessionId(ctx)) return;
        cancelSettle(binding);
        binding.closed = true;
    });
}
