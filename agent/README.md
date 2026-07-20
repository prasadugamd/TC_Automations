# POD Resource Utilization Agent

Three layers work together:

| Layer | Path | Purpose |
|-------|------|---------|
| **CLI orchestrator** | `../pod_res_util_agent.sh` | Runs AKS HTML and/or multi-cloud scripts |
| **Cursor SDK agent** | this folder | Collects report + AI recommendations |
| **Cursor Skill** | `../.cursor/skills/pod-res-util/` | Teaches the IDE agent the same workflow |

## Prerequisites

- Node.js **≥ 22.13**
- `bash` (Git Bash / WSL / Linux)
- `kubectl` or `oc` with cluster access
- `CURSOR_API_KEY` from [Cursor Dashboard → Integrations](https://cursor.com/dashboard/integrations)

## Setup

```bash
cd agent
npm install
export CURSOR_API_KEY="cursor_..."
```

## Usage

```bash
# Live collect (multi-cloud text) + AI analysis
npm run agent -- --mode multicloud --no-email pet01-k8s

# Auto: AKS → HTML, else multi-cloud; then analyze text if present
npm run agent -- --no-email pet01-k8s

# Analyze an existing report only
npm run agent -- --analyze ../reports/pod_res_util_20260720_120000.txt
```

Outputs land in `../reports/`:

- `pod_res_util_*.txt` — multi-cloud text
- `pod_res_util_*.html` — AKS HTML (if that mode ran)
- `ai_analysis_*.md` — Cursor agent recommendations

## Modes

Same as the CLI orchestrator: `auto` | `aks-html` | `multicloud` | `both`

Optional env: `CURSOR_MODEL` (default `composer-2.5`), `KUBE_CMD`, `POOL_LABEL_KEYS`, `PRESSURE_THRESHOLD_PCT`, `TOP_WASTERS`.
