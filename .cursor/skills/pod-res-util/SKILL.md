---
name: pod-res-util
description: >-
  Runs and interprets A1 TC Kubernetes POD / NodePool resource utilization
  reports using MCP tools (pod-res-util), pod_res_util_agent.sh,
  pod_multicloud_resource_utilization.sh, and pod_aks_resource_utilization_html.sh.
  Use when the user asks about pod resource utilization, agent pool or node pool
  capacity, schedulable vs idle CPU/memory, pool pressure, pending pods,
  over-provisioned containers, rightsizing requests, multi-cloud (AKS EKS GKE
  OKE OCP) utilization, MCP pod-res-util tools, or the POD RES UTIL HTML email report.
---

# POD Resource Utilization

## When to use

Apply this skill whenever the user wants capacity, pressure, pending-pod, or rightsizing insight from the scripts in this repo.

## Scripts (prefer this order)

| Tool | Path | Role |
|------|------|------|
| MCP server | `agent/src/mcp-server.ts` (`.cursor/mcp.json`) | Prefer when MCP `pod-res-util` is enabled |
| CLI orchestrator | `pod_res_util_agent.sh` | Chooses AKS HTML vs multi-cloud; writes `reports/` |
| Multi-cloud text | `pod_multicloud_resource_utilization.sh` | AKS/EKS/GKE/OKE/OCP text tables |
| AKS HTML | `pod_aks_resource_utilization_html.sh` | Styled HTML (+ optional email) |
| Cursor SDK agent | `agent/` | CLI AI analysis (`CURSOR_API_KEY`) |

## How to run

### 0. Prefer MCP tools (when available)

Use MCP server **pod-res-util**:

1. `run_pod_resource_report` — namespaces + mode (`multicloud` / `aks-html` / `both` / `auto`), `no_email=true`
2. Optionally `build_pod_resource_analysis_prompt` or analyze the returned `report_text`
3. `list_pod_resource_reports` / `read_pod_resource_report` for prior runs

Do not send email unless the user asks (`no_email` stays true).

### 1. Default CLI (auto mode)

```bash
bash ./pod_res_util_agent.sh <namespace> [namespace...]
```

- Detects cloud from node labels.
- **AKS** → HTML report (`SEND_EMAIL` defaults may send mail — use `--no-email` unless asked).
- **Other** → multi-cloud text report.

### 2. Explicit modes

```bash
bash ./pod_res_util_agent.sh --mode multicloud <ns>
bash ./pod_res_util_agent.sh --mode aks-html --no-email <ns>
bash ./pod_res_util_agent.sh --mode both --no-email <ns>
```

### 3. Useful env vars

- `KUBE_CMD=oc` — OpenShift CLI
- `POOL_LABEL_KEYS=a1.at/node-pool` — custom pool grouping
- `PRESSURE_THRESHOLD_PCT=20` — pool pressure threshold
- `TOP_WASTERS=15` — waster table size
- `SEND_EMAIL=false` / `DRY_RUN=true` — HTML email controls
- `HTML=/path/out.html` — HTML output path

### 4. AI analysis (SDK)

```bash
cd agent && npm install
export CURSOR_API_KEY=cursor_...
npm run agent -- --mode multicloud --no-email <ns>
# or analyze an existing text report:
npm run agent -- --analyze ../reports/pod_res_util_YYYYMMDD_HHMMSS.txt
```

## How to interpret output

Explain these columns clearly to the user:

- **Capacity** — sum of node allocatable in the pool
- **Reserved** — container **requests** × desired replicas (scheduler view)
- **Lim Reserved** — container **limits** × desired replicas
- **In-Use** — live usage from `kubectl`/`oc` top
- **Schedulable** — Capacity − Reserved (≤0 → new pods Pending)
- **Idle** — Capacity − In-Use

### Pressure status legend

- **CRITICAL - add nodes** — Schedulable AND Idle both low → need capacity
- **RESERVED BUT IDLE - rightsize** — Schedulable low, Idle OK → trim requests
- **HOT - investigate bursts** — Schedulable OK, Idle low → burst / missing limits

### Suggested requests

- CPU ≈ usage × 1.5, Memory ≈ usage × 1.3, rounded, capped at current request
- Single `top` sample only — warn for bursty workloads; recommend p95 / krr

## Agent behavior rules

1. Prefer MCP `run_pod_resource_report` when the pod-res-util MCP server is connected; else `pod_res_util_agent.sh`. Do not call child scripts directly unless asked.
2. Default to `--no-email` / `SEND_EMAIL=false` unless the user explicitly wants email sent.
3. Do not invent metrics; only cite numbers from the report output.
4. After a run, point the user to files under `reports/` (`.txt`, `.html`, `.summary.md`).
5. For multi-cloud / OCP / EKS / OCI / GKE questions, use `--mode multicloud` (or `both`).
6. For AKS HTML/email workflows, use `--mode aks-html`.

## Response shape (when summarizing a run)

1. Overall risk: OK / WARN / CRITICAL
2. Pools under pressure (with status)
3. Pending pods (if any)
4. Top rightsizing opportunities
5. Recommended next actions
