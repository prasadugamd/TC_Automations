# POD Resource Utilization

Multi-cloud Kubernetes POD / NodePool resource utilization reports and AI agent for [prasadugamd/POD_RESOURCE_UTIL](https://github.com/prasadugamd/POD_RESOURCE_UTIL).

## Components

| Path | Purpose |
|------|---------|
| `pod_res_util_agent.sh` | CLI orchestrator (AKS HTML and/or multi-cloud text) |
| `pod_multicloud_resource_utilization.sh` | Text report for AKS / EKS / GKE / OKE / OCP |
| `pod_aks_resource_utilization_html.sh` | AKS HTML report (+ optional email) |
| `pod_aks_resource_utilization.sh` | AKS text report (legacy / reference) |
| `agent/` | Cursor SDK CLI + **MCP server** (`npm run mcp`) |
| `.cursor/mcp.json` | Cursor MCP registration for `pod-res-util` |
| `.cursor/skills/pod-res-util/` | Cursor IDE skill |

## Quick start

```bash
# Multi-cloud text report
bash ./pod_res_util_agent.sh --mode multicloud <namespace>

# AKS HTML (no email)
bash ./pod_res_util_agent.sh --mode aks-html --no-email <namespace>

# Both
bash ./pod_res_util_agent.sh --mode both --no-email <namespace>
```

### Cursor SDK agent

```bash
cd agent && npm install
export CURSOR_API_KEY=cursor_...
npm run agent -- --mode multicloud --no-email <namespace>
```

Requires Node.js ≥ 22.13. See [agent/README.md](agent/README.md).

## Env vars

`KUBE_CMD`, `POOL_LABEL_KEYS`, `PRESSURE_THRESHOLD_PCT`, `TOP_WASTERS`, `SEND_EMAIL`, `DRY_RUN`, `HTML`, `ENV_NAME`, `MAIL_TO`
