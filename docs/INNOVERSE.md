# Innoverse — POD Resource Utilization

One-pager for listing, demos, and stakeholder handoff.

## Product blurb (copy/paste)

> **POD Resource Utilization** analyzes Kubernetes / OpenShift namespaces and reports **node-pool capacity** (Reserved vs In-Use vs Schedulable vs Idle), **pool pressure**, **pending pods**, and **rightsizing suggestions**. Works on **AKS, EKS, GKE, OKE, and OCP**. Delivered as Bash CLI reports plus optional **Cursor MCP** tools for AI-assisted review.

## Category suggestions

- Platform Engineering / SRE  
- Kubernetes FinOps / Capacity  
- AI-assisted Ops (MCP)

## Audience

| Role | Value |
|------|--------|
| Platform / SRE | Pool pressure, Pending, capacity headroom |
| App owners | Over-provisioned containers, suggested requests |
| Leadership | Clear CRITICAL vs rightsize vs burst statuses |

## Delivery package

| Item | Location |
|------|----------|
| Source | https://github.com/prasadugamd/POD_RESOURCE_UTIL |
| Version | v1.1.0 (see CHANGELOG.md) |
| Entry CLI | `bash ./pod_res_util_agent.sh --mode multicloud <ns>` |
| MCP | `agent/` + `.cursor/mcp.json` |
| Demo script | [DEMO_SCRIPT.md](DEMO_SCRIPT.md) |

## Maturity

| Area | Status |
|------|--------|
| Multi-cloud text report | Production-ready for pilot |
| AKS HTML report | Production-ready for pilot (email **opt-in**) |
| MCP / Cursor agent | Pilot — requires Node 22.13+ and Cursor |
| Automated tests / CI | Not included in v1.1 |
| Guaranteed SLO | Best-effort / sample-based (`kubectl top`) |

**Label in Innoverse:** *Pilot — Demo ready*

## Security & compliance notes

- Requires existing cluster RBAC (`get/list` pods, nodes, events; `top` via metrics).
- Does **not** modify cluster workloads (read-only reporting).
- Email is **disabled by default**; enable only with `SEND_EMAIL=true` or `--send-email`.
- Do not commit cluster dumps or secrets into the repo.
- `CURSOR_API_KEY` is optional and only for CLI AI analysis (never commit keys).

## Prerequisites checklist (stakeholder laptop)

- [ ] Git clone of `POD_RESOURCE_UTIL`
- [ ] `bash` available
- [ ] `kubectl`/`oc` configured to target cluster
- [ ] `kubectl top nodes` works
- [ ] (Optional) Node.js ≥ 22.13 for MCP
- [ ] (Optional) Cursor IDE with MCP enabled

## Success criteria for a demo

1. Orchestrator exits 0 for a known namespace  
2. `reports/pod_res_util_*.txt` (or `.html`) created  
3. Pool pressure / wasters sections readable  
4. (Optional) MCP tool `run_pod_resource_report` returns JSON paths  

## Known limitations

- Single `kubectl top` sample — bursty apps need p95 / Prometheus / krr  
- Fractional exotic CPU units may be skipped  
- Init containers not counted  
- Per-pod metrics loop can be slow on very large namespaces  
- AI analysis needs structured **text** report (`multicloud` or `both`), not HTML-only  

## FAQ

**Q: Do we need Cursor?**  
A: No for Bash reports. Yes for MCP tools.

**Q: Will it email automatically?**  
A: No. Email is opt-in.

**Q: AKS only?**  
A: No — multi-cloud labels are auto-detected; override with `POOL_LABEL_KEYS`.

**Q: Can we run in CI?**  
A: Yes for Bash modes if the runner has kubeconfig + metrics. MCP is IDE-oriented.

## Owner

Prasadu Gamini — `prasadu.gamini@extern.A1.at` / `Prasadu.Gamini@amdocs.com`
