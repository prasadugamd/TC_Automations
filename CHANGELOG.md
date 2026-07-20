# Changelog

## v1.1.0 — 2026-07-20 (Innoverse pilot)

### Added
- Multi-cloud text report (`pod_multicloud_resource_utilization.sh`)
- CLI orchestrator (`pod_res_util_agent.sh`)
- Cursor MCP server (`agent/src/mcp-server.ts`) with tools:
  - `run_pod_resource_report`
  - `list_pod_resource_reports`
  - `read_pod_resource_report`
  - `build_pod_resource_analysis_prompt`
- Cursor SDK CLI agent (`agent/src/index.ts`)
- Cursor IDE skill (`.cursor/skills/pod-res-util`)
- Innoverse docs (`docs/INNOVERSE.md`, `docs/DEMO_SCRIPT.md`)

### Fixed
- Email default is **off** unless explicitly enabled (`--send-email` / `SEND_EMAIL=true`)
- HTML-only mode no longer feeds orchestrator logs into AI analysis

### Notes
- Label as **Pilot / Demo ready** on Innoverse
- Shell reports do not require Node.js; MCP/agent require Node ≥ 22.13

## v1.0.0 — earlier

- AKS HTML and AKS text utilization reports
