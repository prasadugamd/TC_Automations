# POD Resource Utilization

**Innoverse status:** Pilot / v1.1 — ready for demo and limited stakeholder rollout  
**Repo:** [prasadugamd/POD_RESOURCE_UTIL](https://github.com/prasadugamd/POD_RESOURCE_UTIL)  
**Owner:** Prasadu Gamini  

Multi-cloud Kubernetes **POD / NodePool** capacity reporting with optional **MCP** and **Cursor** AI analysis.

| Capability | Supported |
|------------|-----------|
| Platforms | AKS, EKS (+ Karpenter), GKE, OCI OKE, OpenShift (OCP) |
| Outputs | Text tables, HTML report, pressure alerts, pending pods, rightsizing hints |
| Interfaces | Bash CLI · Cursor MCP · Cursor SDK agent · IDE skill |

---

## What stakeholders get

1. **Schedulable vs Idle** view per node pool (scheduler booking vs live usage)
2. **Pool pressure** statuses: CRITICAL / RESERVED BUT IDLE / HOT
3. **Pending pods** with FailedScheduling reasons
4. **Top over-provisioned containers** with suggested requests
5. Optional **MCP tools** inside Cursor for assisted analysis

---

## Prerequisites

| Requirement | Notes |
|-------------|--------|
| `bash` | Git Bash / WSL / Linux |
| `kubectl` or `oc` | Cluster context already logged in |
| Metrics | `kubectl top` / metrics-server (or OpenShift metrics) |
| Node.js ≥ 22.13 | **Only** for MCP / Cursor SDK agent |
| Cursor IDE | **Only** for MCP tools |

Shell reports work **without** Node.js or Cursor.

---

## 5-minute quick start (demo-safe)

Email is **off by default**. Reports write under `./reports/`.

```bash
git clone https://github.com/prasadugamd/POD_RESOURCE_UTIL.git
cd POD_RESOURCE_UTIL

# Recommended demo: multi-cloud text report
bash ./pod_res_util_agent.sh --mode multicloud <namespace>

# AKS HTML (no email)
bash ./pod_res_util_agent.sh --mode aks-html <namespace>

# Both text + HTML
bash ./pod_res_util_agent.sh --mode both <namespace>
```

OpenShift:

```bash
KUBE_CMD=oc bash ./pod_res_util_agent.sh --mode multicloud <namespace>
```

Custom pool label (recommended for OCI / mixed clouds):

```bash
POOL_LABEL_KEYS=a1.at/node-pool bash ./pod_res_util_agent.sh --mode multicloud <namespace>
```

---

## MCP (Cursor)

```bash
cd agent
npm install
```

Project MCP config is in [`.cursor/mcp.json`](.cursor/mcp.json). Reload MCP servers in Cursor, then ask:

> Use `run_pod_resource_report` for namespace `<ns>` with mode `multicloud`, then summarize pool pressure.

| MCP tool | Purpose |
|----------|---------|
| `run_pod_resource_report` | Collect report |
| `list_pod_resource_reports` | List `reports/` |
| `read_pod_resource_report` | Read a report file |
| `build_pod_resource_analysis_prompt` | Host-LLM analysis prompt |

Details: [agent/README.md](agent/README.md) · [docs/INNOVERSE.md](docs/INNOVERSE.md)

---

## Cursor SDK CLI (optional AI)

```bash
cd agent && npm install
export CURSOR_API_KEY=cursor_...   # https://cursor.com/dashboard/integrations
npm run agent -- --mode multicloud <namespace>
```

Use `--send-email` only when stakeholders explicitly want HTML mail.

---

## Repository layout

| Path | Role |
|------|------|
| `pod_res_util_agent.sh` | CLI orchestrator (preferred entrypoint) |
| `pod_multicloud_resource_utilization.sh` | Multi-cloud text report |
| `pod_aks_resource_utilization_html.sh` | AKS HTML report |
| `pod_aks_resource_utilization.sh` | AKS text (legacy) |
| `agent/` | MCP server + Cursor SDK agent |
| `.cursor/mcp.json` | Cursor MCP registration |
| `.cursor/skills/pod-res-util/` | Cursor IDE skill |
| `docs/INNOVERSE.md` | Stakeholder / Innoverse one-pager |
| `docs/DEMO_SCRIPT.md` | 10-minute demo script |
| `CHANGELOG.md` | Release history |

---

## Environment variables

| Variable | Default | Meaning |
|----------|---------|---------|
| `KUBE_CMD` | `kubectl` | Or `oc` |
| `POOL_LABEL_KEYS` | (auto) | Comma-separated pool label keys |
| `PRESSURE_THRESHOLD_PCT` | `20` | Pool pressure threshold |
| `TOP_WASTERS` | `15` | Over-provisioned table size |
| `SEND_EMAIL` | `false` | HTML email (opt-in) |
| `DRY_RUN` | `false` | Generate HTML but skip send |
| `HTML` | under `reports/` | HTML output path |
| `ENV_NAME` / `MAIL_TO` / `MAIL_FROM` | — | Email metadata when sending |

---

## Support & versioning

- **Version:** see [CHANGELOG.md](CHANGELOG.md) (`v1.1.0`)
- **Contact:** Prasadu Gamini (`prasadu.gamini@extern.A1.at`)
- **License / distribution:** internal A1 / Amdocs use via Innoverse & GitHub

For Innoverse listing copy and FAQ, see **[docs/INNOVERSE.md](docs/INNOVERSE.md)**.
