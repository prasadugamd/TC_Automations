/**
 * Shared helpers for CLI agent and MCP server.
 * MCP must not write to stdout (reserved for JSON-RPC) — use echo=false.
 */

import { spawn } from "node:child_process";
import { existsSync } from "node:fs";
import { mkdir, readdir, readFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));

export const REPO_ROOT = path.resolve(__dirname, "../..");
export const ORCHESTRATOR = path.join(REPO_ROOT, "pod_res_util_agent.sh");
export const REPORTS_DIR = path.join(REPO_ROOT, "reports");

export type ReportMode = "auto" | "aks-html" | "multicloud" | "both";

export function runCommand(
  command: string,
  args: string[],
  cwd: string,
  options?: { env?: NodeJS.ProcessEnv; echo?: boolean },
): Promise<{ code: number; stdout: string; stderr: string }> {
  const echo = options?.echo ?? false;
  return new Promise((resolve, reject) => {
    const child = spawn(command, args, {
      cwd,
      env: { ...process.env, ...options?.env },
      shell: process.platform === "win32",
    });
    let stdout = "";
    let stderr = "";
    child.stdout.on("data", (d: Buffer) => {
      const s = d.toString();
      stdout += s;
      if (echo) process.stdout.write(s);
    });
    child.stderr.on("data", (d: Buffer) => {
      const s = d.toString();
      stderr += s;
      if (echo) process.stderr.write(s);
    });
    child.on("error", reject);
    child.on("close", (code) => resolve({ code: code ?? 1, stdout, stderr }));
  });
}

export async function findLatestTextReport(
  reportsDir: string = REPORTS_DIR,
): Promise<string | undefined> {
  if (!existsSync(reportsDir)) return undefined;
  const files = (await readdir(reportsDir))
    .filter(
      (f) =>
        f.endsWith(".txt") &&
        !f.startsWith("orchestrator_stdout_") &&
        f.startsWith("pod_res_util_"),
    )
    .sort()
    .reverse();
  return files[0] ? path.join(reportsDir, files[0]) : undefined;
}

export async function listReports(reportsDir: string = REPORTS_DIR): Promise<string[]> {
  if (!existsSync(reportsDir)) return [];
  const files = await readdir(reportsDir);
  return files
    .filter((f) => /\.(txt|html|md|summary\.md)$/i.test(f) || f.endsWith(".summary.md"))
    .sort()
    .reverse()
    .map((f) => path.join(reportsDir, f));
}

export type RunReportInput = {
  namespaces: string[];
  mode?: ReportMode;
  /** When false, allow HTML email. Default / true / undefined => never send. */
  noEmail?: boolean;
  kubeCmd?: string;
  poolLabelKeys?: string;
  pressureThresholdPct?: number;
  topWasters?: number;
  echo?: boolean;
};

export type RunReportResult = {
  code: number;
  mode: ReportMode;
  textReportPath?: string;
  htmlReportPath?: string;
  summaryPath?: string;
  stdout: string;
  stderr: string;
};

export async function runPodResourceReport(input: RunReportInput): Promise<RunReportResult> {
  const mode = input.mode ?? "auto";
  if (!existsSync(ORCHESTRATOR)) {
    throw new Error(`Missing orchestrator: ${ORCHESTRATOR}`);
  }
  if (!input.namespaces.length) {
    throw new Error("At least one namespace is required");
  }

  await mkdir(REPORTS_DIR, { recursive: true });

  // Email is opt-in only. Default / undefined => do not send.
  const allowEmail = input.noEmail === false;

  const orchArgs = ["--mode", mode, "--out-dir", REPORTS_DIR];
  if (!allowEmail) orchArgs.push("--no-email");
  orchArgs.push(...input.namespaces);

  const env: NodeJS.ProcessEnv = {
    SEND_EMAIL: allowEmail ? "true" : "false",
  };
  if (input.kubeCmd) env.KUBE_CMD = input.kubeCmd;
  if (input.poolLabelKeys) env.POOL_LABEL_KEYS = input.poolLabelKeys;
  if (input.pressureThresholdPct != null) {
    env.PRESSURE_THRESHOLD_PCT = String(input.pressureThresholdPct);
  }
  if (input.topWasters != null) env.TOP_WASTERS = String(input.topWasters);

  const run = await runCommand("bash", [ORCHESTRATOR, ...orchArgs], REPO_ROOT, {
    env,
    echo: input.echo ?? false,
  });

  // Only use real multi-cloud .txt reports — never invent one from orchestrator logs.
  const textReportPath = await findLatestTextReport(REPORTS_DIR);

  const all = await listReports(REPORTS_DIR);
  const htmlReportPath = all.find((p) => p.endsWith(".html"));
  const summaryPath = all.find((p) => p.endsWith(".summary.md"));

  return {
    code: run.code,
    mode,
    textReportPath,
    htmlReportPath,
    summaryPath,
    stdout: run.stdout,
    stderr: run.stderr,
  };
}

export function clipText(text: string, max = 100_000): string {
  if (text.length <= max) return text;
  return text.slice(0, max) + "\n\n[... truncated ...]\n";
}

export function buildAnalysisPrompt(reportText: string, meta: Record<string, string>): string {
  const clipped = clipText(reportText, 120_000);
  return `You are a Kubernetes capacity and rightsizing advisor for A1 TC platforms (AKS / EKS / GKE / OKE / OCP).

Analyze the POD resource utilization report below and produce actionable recommendations.

Context:
${Object.entries(meta)
  .map(([k, v]) => `- ${k}: ${v}`)
  .join("\n")}

Report:
\`\`\`
${clipped}
\`\`\`

Respond in markdown with these sections only:
1. **Executive summary** (3-5 bullets; overall risk: OK / WARN / CRITICAL)
2. **Pool pressure** — which pools need nodes vs rightsizing vs burst investigation
3. **Pending pods** — root causes and fix order
4. **Top rightsizing opportunities** — concrete request changes (CPU/Mem) with expected freed capacity
5. **Next actions** — prioritized checklist for the platform team

Be specific to numbers in the report. Do not invent metrics that are not present.`;
}

export async function readReportFile(filePath: string): Promise<string> {
  const resolved = path.isAbsolute(filePath) ? filePath : path.resolve(REPO_ROOT, filePath);
  if (!existsSync(resolved)) {
    throw new Error(`Report not found: ${resolved}`);
  }
  return readFile(resolved, "utf8");
}
