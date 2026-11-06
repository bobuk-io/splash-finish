// Managed by Splash Finish. Reinstall to update; uninstall-skills removes this file.
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { execFile } from "node:child_process";
import { basename } from "node:path";

type Notice = { task: string; status: "done" | "attention" | "running"; title: string; detail: string; project: string; run: number; sequence: number };
type Sender = (notice: Notice) => Promise<void>;

function send(notice: Notice): Promise<void> {
    // The installer injects the absolute bundled binary path. No shell, no PATH dependency.
    const executable: string = __EXECUTABLE_JSON__;
    const args = ["notify", "--agent", "pi", "--task", notice.task, "--status", notice.status,
        "--title", notice.title || "Response completed",
        "--run", String(notice.run), "--sequence", String(notice.sequence)];
    // Omit empty fields so the CLI can apply its own fallbacks instead of storing blanks.
    if (notice.detail) args.push("--detail", notice.detail);
    if (notice.project) args.push("--project", notice.project);
    return new Promise(resolve => {
        execFile(executable, args, { timeout: 2500, maxBuffer: 16384 }, () => resolve());
    });
}

/**
 * Background subagents set PI_SUBAGENT_CHILD; in-process children run from
 * <session-root>/run-N/session.jsonl. Their lifecycle events would duplicate or
 * drown out the parent session, so only requests for input are forwarded.
 */
function isChildSession(ctx: ExtensionContext): boolean {
    if (process.env.PI_SUBAGENT_CHILD === "1") return true;
    try {
        const file = ctx.sessionManager.getSessionFile?.();
        return typeof file === "string" && /\/run-\d+\/session\.jsonl$/.test(file);
    } catch { return false; }
}

/** The injectable sender also permits lifecycle tests without starting the macOS app. */
export function register(pi: ExtensionAPI, emit: Sender = send): void {
    let lastText = "";
    let failed = false;
    let active = false;
    let run = Date.now();
    let sequence = 0;
    // Notifications are fire-and-forget. Awaiting the child process here would delay the
    // agent on every lifecycle event. Out-of-order delivery is safe: the inbox orders
    // updates by run and sequence and ignores stale generations.
    const notice = (ctx: ExtensionContext, status: Notice["status"], title: string, detail = "") => {
        if (status !== "attention" && isChildSession(ctx)) return;
        try {
            const currentSequence = ++sequence;
            void emit({ task: ctx.sessionManager.getSessionId(), status, title,
                detail, project: basename(ctx.cwd), run, sequence: currentSequence }).catch(() => {});
        } catch { /* Notifications must never interrupt the agent. */ }
    };
    pi.on("before_agent_start", async (_event, ctx) => {
        active = true; lastText = ""; failed = false;
        run = Math.max(Date.now(), run + 1); sequence = 0;
        notice(ctx, "running", "Working");
    });
    pi.on("message_end", async (event) => {
        if (event.message.role !== "assistant") return;
        lastText = event.message.content.filter(part => part.type === "text")
            .map(part => part.type === "text" ? part.text : "").join(" ");
        failed = event.message.stopReason === "error";
    });
    // agent_end can be followed by retries, compaction or queued continuations.
    // Pi >= 1.5 exposes the final notification-only settled boundary.
    pi.on("agent_settled", async (event, ctx) => {
        if (!active) return;
        active = false;
        if (event.aborted) { notice(ctx, "running", "Interrupted"); return; }
        notice(ctx, failed ? "attention" : "done",
            failed ? "Agent stopped with an error" : lastText.replace(/\s+/g, " ").slice(0, 110) || "Response completed",
            failed ? "Open the session for details" : "Ready for review");
    });
    pi.on("ui_prompt_start", async (event, ctx) => {
        notice(ctx, "attention", event.title || "Waiting for your input", "An agent needs your answer");
    });
    pi.on("ui_prompt_end", async (_event, ctx) => { notice(ctx, "running", "Working"); });
    pi.on("tool_call", async (event, ctx) => {
        if (["ask_user", "question", "questionnaire"].includes(event.toolName)) {
            notice(ctx, "attention", "Waiting for your input", "An agent needs your answer");
        }
    });
    pi.on("tool_execution_end", async (event, ctx) => {
        if (["ask_user", "question", "questionnaire"].includes(event.toolName)) {
            notice(ctx, "running", "Working");
        }
    });
    pi.on("session_shutdown", async (_event, ctx) => {
        if (active) notice(ctx, "running", "Session closed");
    });
}

export default function (pi: ExtensionAPI): void { register(pi); }
