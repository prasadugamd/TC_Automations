# POD Resource Utilization Agent

Four layers work together:

| Layer | Path | Purpose |
|-------|------|---------|
| **CLI orchestrator** | `../pod_res_util_agent.sh` | Runs AKS HTML and/or multi-cloud scripts |
| **Cursor SDK agent** | `npm run agent` | Collects report + AI recommendations |
| **MCP server** | `npm run mcp` | Exposes tools to Cursor / MCP hosts |
| **Cursor Skill** | `../.cursor/skills/pod-res-util/` | Teaches the IDE agent the workflow |

## Prerequisites

- Node.js **≥ 22.13**
- `bash` (Git Bash / WSL / Linux)
- `kubectl` or `oc` with cluster access
- `CURSOR_API_KEY` only for CLI `npm run agent` AI analysis (MCP uses the host LLM)

## Setup

```bash
cd agent
npm install
```

## MCP (Cursor)

Project config: `../.cursor/mcp.json`

1. `cd agent && npm install`
2. Restart Cursor / reload MCP servers
3. Confirm tools under **pod-res-util**:  
   `run_pod_resource_report`, `list_pod_resource_reports`, `read_pod_resource_report`, `build_pod_resource_analysis_prompt`

Manual start (debug):

```bash
npm run mcp
```

Example host prompt: *“Use run_pod_resource_report for namespace pet01-k8s in multicloud mode, then analyze capacity.”*

## CLI (Cursor SDK)

```bash
export CURSOR_API_KEY="cursor_..."
npm run agent -- --mode multicloud pet01-k8s
npm run agent -- --analyze ../reports/pod_res_util_20260720_120000.txt
# Email is off by default; opt in only when needed:
npm run agent -- --mode aks-html --send-email pet01-k8s
```

Outputs land in `../reports/`. AI analysis needs a structured `.txt` report (`multicloud` or `both`). `aks-html` alone skips analysis and points at the HTML file.

## Modes

`auto` | `aks-html` | `multicloud` | `both`

Env: `CURSOR_MODEL`, `KUBE_CMD`, `POOL_LABEL_KEYS`, `PRESSURE_THRESHOLD_PCT`, `TOP_WASTERS`, `SEND_EMAIL`.
