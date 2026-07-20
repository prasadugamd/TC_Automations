/**
 * POD Resource Utilization — Cursor SDK agent
 *
 * 1) Runs the CLI orchestrator (or analyzes an existing report)
 * 2) Asks a local Cursor agent to produce capacity / rightsizing recommendations
 *
 * Requires: CURSOR_API_KEY, Node >= 22.13, kubectl/oc access for live runs
 */

import { spawn } from "node:child_process";
import { existsSync } from "node:fs";
import { readFile, writeFile, mkdir } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { Agent, CursorAgentError } from "@cursor/sdk";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = path.resolve(__dirname, "../..");
const AGENT_DIR = path.resolve(__dirname, "..");
const ORCHESTRATOR = path.join(REPO_ROOT, "pod_res_util_agent.sh");

type CliArgs = {
  mode: "auto" | "aks-html" | "multicloud" | "both";
  namespaces: string[];
  analyzeOnly: boolean;
  reportPath?: string;
  noEmail: boolean;
  model: string;
};

function usage(): never {
  console.error(`Usage:
  npm run agent -- [--mode auto|aks-html|multicloud|both] [--no-email] <ns> [ns...]
  npm run agent -- --analyze <report.txt>
  npm run analyze -- --analyze <report.txt>

Env:
  CURSOR_API_KEY   required
  CURSOR_MODEL     optional (default: composer-2.5)
`);
  process.exit(1);
}

function parseArgs(argv: string[]): CliArgs {
  const args: CliArgs = {
    mode: "auto",
    namespaces: [],
    analyzeOnly: false,
    noEmail: false,
    model: process.env.CURSOR_MODEL || "composer-2.5",
  };

  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === "--mode") {
      const v = argv[++i] as CliArgs["mode"];
      if (!["auto", "aks-html", "multicloud", "both"].includes(v)) usage();
      args.mode = v;
    } else if (a === "--no-email") {
      args.noEmail = true;
    } else if (a === "--analyze" || a === "--analyze-only") {
      args.analyzeOnly = true;
      if (a === "--analyze" && argv[i + 1] && !argv[i + 1].startsWith("-")) {
        args.reportPath = argv[++i];
      }
    } else if (a === "-h" || a === "--help") {
      usage();
    } else if (a.startsWith("-")) {
      console.error(`Unknown option: ${a}`);
      usage();
    } else {
      args.namespaces.push(a);
    }
  }

  if (!args.analyzeOnly && args.namespaces.length === 0) usage();
  if (args.analyzeOnly && !args.reportPath) {
    console.error("--analyze requires a report file path");
    usage();
  }
  return args;
}

function runCommand(
  command: string,
  args: string[],
  cwd: string,
  env?: NodeJS.ProcessEnv,
): Promise<{ code: number; stdout: string; stderr: string }> {
  return new Promise((resolve, reject) => {
    const child = spawn(command, args, {
      cwd,
      env: { ...process.env, ...env },
      shell: process.platform === "win32",
    });
    let stdout = "";
    let stderr = "";
    child.stdout.on("data", (d: Buffer) => {
      const s = d.toString();
      stdout += s;
      process.stdout.write(s);
    });
    child.stderr.on("data", (d: Buffer) => {
      const s = d.toString();
      stderr += s;
      process.stderr.write(s);
    });
    child.on("error", reject);
    child.on("close", (code) => {
      resolve({ code: code ?? 1, stdout, stderr });
    });
  });
}

async function findLatestTextReport(reportsDir: string): Promise<string | undefined> {
  if (!existsSync(reportsDir)) return undefined;
  const { readdir } = await import("node:fs/promises");
  const files = (await readdir(reportsDir))
    .filter((f) => f.endsWith(".txt"))
    .sort()
    .reverse();
  return files[0] ? path.join(reportsDir, files[0]) : undefined;
}

function buildAnalysisPrompt(reportText: string, meta: Record<string, string>): string {
  const clipped =
    reportText.length > 120_000
      ? reportText.slice(0, 120_000) + "\n\n[... truncated for prompt size ...]\n"
      : reportText;

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

async function analyzeWithCursor(
  reportText: string,
  meta: Record<string, string>,
  modelId: string,
): Promise<string> {
  const apiKey = process.env.CURSOR_API_KEY?.trim();
  if (!apiKey) {
    throw new Error("CURSOR_API_KEY is not set. Export it before running the SDK agent.");
  }

  const result = await Agent.prompt(buildAnalysisPrompt(reportText, meta), {
    apiKey,
    model: { id: modelId },
    local: { cwd: REPO_ROOT },
  });

  if (result.status === "error") {
    throw new Error(`Cursor agent run failed (run id: ${result.id})`);
  }

  return result.result ?? "(no analysis text returned)";
}

async function main(): Promise<void> {
  const args = parseArgs(process.argv.slice(2));
  const reportsDir = path.join(REPO_ROOT, "reports");
  await mkdir(reportsDir, { recursive: true });

  let reportPath = args.reportPath;
  let orchestratorCode = 0;

  if (!args.analyzeOnly) {
    if (!existsSync(ORCHESTRATOR)) {
      console.error(`Missing orchestrator: ${ORCHESTRATOR}`);
      process.exit(1);
    }

    const orchArgs = ["--mode", args.mode, "--out-dir", reportsDir];
    if (args.noEmail) orchArgs.push("--no-email");
    orchArgs.push(...args.namespaces);

    console.log("\n=== Running CLI orchestrator ===\n");
    // Git Bash / WSL / bash on PATH
    const bashCmd = process.platform === "win32" ? "bash" : "bash";
    const run = await runCommand(bashCmd, [ORCHESTRATOR, ...orchArgs], REPO_ROOT, {
      SEND_EMAIL: args.noEmail ? "false" : process.env.SEND_EMAIL,
    });
    orchestratorCode = run.code;

    reportPath = await findLatestTextReport(reportsDir);
    if (!reportPath && args.mode === "aks-html") {
      // HTML-only mode: still ask agent using orchestrator stdout
      const fallback = path.join(reportsDir, `orchestrator_stdout_${Date.now()}.txt`);
      await writeFile(fallback, run.stdout || run.stderr || "(empty)", "utf8");
      reportPath = fallback;
    }
  }

  if (!reportPath || !existsSync(reportPath)) {
    console.error(
      "No text report found to analyze. Use --mode multicloud|both, or --analyze <file>.",
    );
    process.exit(orchestratorCode || 1);
  }

  const reportText = await readFile(reportPath, "utf8");
  const meta = {
    report: reportPath,
    mode: args.mode,
    namespaces: args.namespaces.join(" ") || "(from report)",
    model: args.model,
  };

  console.log("\n=== Cursor SDK analysis ===\n");
  let analysis: string;
  try {
    analysis = await analyzeWithCursor(reportText, meta, args.model);
  } catch (err) {
    if (err instanceof CursorAgentError) {
      console.error(`Cursor startup failed: ${err.message}`);
      process.exit(1);
    }
    throw err;
  }

  const analysisPath = path.join(
    reportsDir,
    `ai_analysis_${new Date().toISOString().replace(/[:.]/g, "-")}.md`,
  );
  await writeFile(analysisPath, analysis, "utf8");

  console.log(analysis);
  console.log(`\nAI analysis saved: ${analysisPath}`);
  process.exit(orchestratorCode);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
