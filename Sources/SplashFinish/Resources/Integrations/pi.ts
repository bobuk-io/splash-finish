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
        "--title", notice.title || "Response completed", "--detail", notice.detail || " ", "--project", notice.project || " ",
        "--run", String(notice.run), "--sequence", String(notice.sequence)];
    return new Promise(resolve => {
        execFile(executable, args, { timeout: 2500, maxBuffer: 16384 }, () => resolve());
    });
}

/** The injectable sender also permits lifecycle tests without starting the macOS app. */
export function register(pi: ExtensionAPI, emit: Sender = send): void {
    let lastText = "";
    let failed = false;
    let active = false;
    let run = Date.now();
    let sequence = 0;
    const notice = async (ctx: ExtensionContext, status: Notice["status"], title: string, detail = "") => {
        try {
            const currentSequence = ++sequence;
            await emit({ task: ctx.sessionManager.getSessionId(), status, title,
                detail, project: basename(ctx.cwd), run, sequence: currentSequence });
        } catch { /* Notifications must never interrupt the agent. */ }
    };
    pi.on("before_agent_start", async (_event, ctx) => {
        active = true; lastText = ""; failed = false;
        run = Math.max(Date.now(), run + 1); sequence = 0;
        await notice(ctx, "running", "Working");
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
        if (event.aborted) { await notice(ctx, "running", "Interrupted"); return; }
        await notice(ctx, failed ? "attention" : "done",
            failed ? "Agent stopped with an error" : lastText.replace(/\s+/g, " ").slice(0, 110) || "Response completed",
            failed ? "Open the session for details" : "Ready for review");
    });
    pi.on("ui_prompt_start", async (event, ctx) => {
        await notice(ctx, "attention", event.title || "Waiting for your input", "An agent needs your answer");
    });
    pi.on("ui_prompt_end", async (_event, ctx) => { await notice(ctx, "running", "Working"); });
    pi.on("tool_call", async (event, ctx) => {
        if (["ask_user", "question", "questionnaire"].includes(event.toolName)) {
            await notice(ctx, "attention", "Waiting for your input", "An agent needs your answer");
        }
    });
    pi.on("tool_execution_end", async (event, ctx) => {
        if (["ask_user", "question", "questionnaire"].includes(event.toolName)) {
            await notice(ctx, "running", "Working");
        }
    });
    pi.on("session_shutdown", async (_event, ctx) => {
        if (active) await notice(ctx, "running", "Session closed");
    });
}

export default function (pi: ExtensionAPI): void { register(pi); }
