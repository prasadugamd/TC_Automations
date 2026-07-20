#!/usr/bin/env node
/**
 * MCP stdio server for POD Resource Utilization.
 *
 * Tools:
 *   - run_pod_resource_report
 *   - list_pod_resource_reports
 *   - read_pod_resource_report
 *   - build_pod_resource_analysis_prompt
 *
 * IMPORTANT: Do not console.log — stdout is the MCP transport.
 */

import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { z } from "zod";
import { readFile } from "node:fs/promises";
import path from "node:path";
import {
  REPO_ROOT,
  REPORTS_DIR,
  buildAnalysisPrompt,
  clipText,
  listReports,
  readReportFile,
  runPodResourceReport,
  findLatestTextReport,
} from "./lib.js";

const server = new McpServer({
  name: "pod-res-util",
  version: "1.0.0",
});

server.tool(
  "run_pod_resource_report",
  "Run POD / NodePool resource utilization via pod_res_util_agent.sh (AKS HTML and/or multi-cloud text). Defaults to no email. Returns JSON with paths and optional report text.",
  {
    namespaces: z
      .array(z.string())
      .min(1)
      .describe("Kubernetes / OpenShift namespaces to analyze"),
    mode: z
      .enum(["auto", "aks-html", "multicloud", "both"])
      .default("auto")
      .describe("auto | aks-html | multicloud | both"),
    no_email: z
      .boolean()
      .default(true)
      .describe("If true (default), do not send HTML email. Set false only when user explicitly asks to email."),
    kube_cmd: z.string().optional().describe("kubectl or oc"),
    pool_label_keys: z
      .string()
      .optional()
      .describe("Comma-separated custom node pool label keys"),
    pressure_threshold_pct: z.number().int().min(1).max(100).optional(),
    top_wasters: z.number().int().min(1).max(100).optional(),
    include_report_text: z
      .boolean()
      .default(true)
      .describe("Include clipped text report body in the response"),
  },
  async (args) => {
    try {
      const result = await runPodResourceReport({
        namespaces: args.namespaces,
        mode: args.mode,
        noEmail: args.no_email,
        kubeCmd: args.kube_cmd,
        poolLabelKeys: args.pool_label_keys,
        pressureThresholdPct: args.pressure_threshold_pct,
        topWasters: args.top_wasters,
        echo: false,
      });

      let reportText: string | null = null;
      if (args.include_report_text && result.textReportPath) {
        reportText = clipText(await readReportFile(result.textReportPath), 80_000);
      }

      const payload = {
        exit_code: result.code,
        mode: result.mode,
        text_report: result.textReportPath ?? null,
        html_report: result.htmlReportPath ?? null,
        summary: result.summaryPath ?? null,
        reports_dir: REPORTS_DIR,
        stderr_tail: clipText(result.stderr, 4000),
        report_text: reportText,
      };

      return {
        content: [{ type: "text", text: JSON.stringify(payload, null, 2) }],
        isError: result.code !== 0,
      };
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err);
      return {
        content: [{ type: "text", text: `Error: ${message}` }],
        isError: true,
      };
    }
  },
);

server.tool(
  "list_pod_resource_reports",
  "List generated report files under reports/ (newest first).",
  {},
  async () => {
    const files = await listReports();
    return {
      content: [
        {
          type: "text",
          text: files.length
            ? files.map((f) => `- ${f}`).join("\n")
            : `No reports in ${REPORTS_DIR}`,
        },
      ],
    };
  },
);

server.tool(
  "read_pod_resource_report",
  "Read a previously generated report. If path is omitted, reads the latest .txt report.",
  {
    path: z.string().optional().describe("Absolute or repo-relative report path"),
    max_chars: z.number().int().min(1000).max(200_000).default(80_000),
  },
  async (args) => {
    try {
      const target = args.path || (await findLatestTextReport());
      if (!target) {
        return {
          content: [
            {
              type: "text",
              text: "No report found. Call run_pod_resource_report first.",
            },
          ],
          isError: true,
        };
      }
      const text = clipText(await readReportFile(target), args.max_chars ?? 80_000);
      return {
        content: [{ type: "text", text: `File: ${target}\n\n${text}` }],
      };
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err);
      return {
        content: [{ type: "text", text: `Error: ${message}` }],
        isError: true,
      };
    }
  },
);

server.tool(
  "build_pod_resource_analysis_prompt",
  "Build a structured capacity/rightsizing analysis prompt from a report for the host LLM (no CURSOR_API_KEY required).",
  {
    path: z.string().optional().describe("Report path; defaults to latest .txt"),
    namespaces: z.string().optional().describe("Optional namespace context"),
  },
  async (args) => {
    try {
      const target = args.path || (await findLatestTextReport());
      if (!target) {
        return {
          content: [
            {
              type: "text",
              text: "No report found. Call run_pod_resource_report first.",
            },
          ],
          isError: true,
        };
      }
      const reportText = await readReportFile(target);
      const prompt = buildAnalysisPrompt(reportText, {
        report: target,
        namespaces: args.namespaces || "(from report)",
        repo: REPO_ROOT,
      });
      return { content: [{ type: "text", text: prompt }] };
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err);
      return {
        content: [{ type: "text", text: `Error: ${message}` }],
        isError: true,
      };
    }
  },
);

server.resource(
  "skill-guide",
  "pod-res-util://guides/skill",
  async (uri) => {
    const skillPath = path.join(REPO_ROOT, ".cursor/skills/pod-res-util/SKILL.md");
    const text = await readFile(skillPath, "utf8");
    return {
      contents: [
        {
          uri: uri.href,
          mimeType: "text/markdown",
          text,
        },
      ],
    };
  },
);

server.prompt(
  "analyze_pod_capacity",
  "Analyze the latest POD resource utilization report for capacity and rightsizing",
  {
    namespaces: z.string().optional().describe("Namespaces context"),
    path: z.string().optional().describe("Optional report path"),
  },
  async (args) => {
    const target = args.path || (await findLatestTextReport());
    if (!target) {
      return {
        messages: [
          {
            role: "user",
            content: {
              type: "text",
              text: "No report available. Call run_pod_resource_report first.",
            },
          },
        ],
      };
    }
    const reportText = await readReportFile(target);
    const prompt = buildAnalysisPrompt(reportText, {
      report: target,
      namespaces: args.namespaces || "(from report)",
    });
    return {
      messages: [
        {
          role: "user",
          content: { type: "text", text: prompt },
        },
      ],
    };
  },
);

async function main(): Promise<void> {
  const transport = new StdioServerTransport();
  await server.connect(transport);
  console.error(`pod-res-util MCP server started (repo=${REPO_ROOT})`);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
