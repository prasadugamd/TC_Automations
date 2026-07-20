#!/bin/bash
# ============================================================================
#  pod_res_util_agent.sh
# ----------------------------------------------------------------------------
#  CLI orchestrator for POD resource utilization reports.
#  Selects and runs:
#    - pod_aks_resource_utilization_html.sh   (AKS HTML + optional email)
#    - pod_multicloud_resource_utilization.sh (AKS/EKS/GKE/OKE/OCP text)
# ============================================================================
# Usage:
#   ./pod_res_util_agent.sh [--mode auto|aks-html|multicloud|both] <ns> [ns...]
#   ./pod_res_util_agent.sh --mode multicloud pet01-k8s
#   ./pod_res_util_agent.sh --mode aks-html --no-email pet01-k8s
#   ./pod_res_util_agent.sh --mode both DRY_RUN=true pet01-k8s   # env still works
#
# Env (passed through to child scripts):
#   KUBE_CMD, POOL_LABEL_KEYS, PRESSURE_THRESHOLD_PCT, TOP_WASTERS
#   HTML, SEND_EMAIL, DRY_RUN, ENV_NAME, MAIL_TO, MAIL_FROM
# ============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AKS_HTML_SCRIPT="${SCRIPT_DIR}/pod_aks_resource_utilization_html.sh"
MULTI_SCRIPT="${SCRIPT_DIR}/pod_multicloud_resource_utilization.sh"

MODE="auto"
NO_EMAIL=0
NAMESPACES=()
OUT_DIR="${OUT_DIR:-${SCRIPT_DIR}/reports}"
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"

usage() {
  cat <<'EOF'
Usage: pod_res_util_agent.sh [options] <namespace> [namespace...]

Options:
  --mode auto|aks-html|multicloud|both   Report mode (default: auto)
  --no-email                             Force SEND_EMAIL=false for HTML report
  --out-dir DIR                          Report output directory (default: ./reports)
  -h, --help                             Show this help

Modes:
  auto         Detect cloud; AKS -> HTML report, else multicloud text
  aks-html     Always run AKS HTML report script
  multicloud   Always run multi-cloud text report
  both         Run both scripts

Examples:
  ./pod_res_util_agent.sh pet01-k8s
  ./pod_res_util_agent.sh --mode multicloud --no-email ns-a ns-b
  KUBE_CMD=oc ./pod_res_util_agent.sh --mode multicloud openshift-monitoring
  POOL_LABEL_KEYS=a1.at/node-pool ./pod_res_util_agent.sh --mode both my-ns
EOF
}

detect_cloud_hint() {
  local KUBE="${KUBE_CMD:-kubectl}"
  if ! command -v "$KUBE" >/dev/null 2>&1; then
    if command -v oc >/dev/null 2>&1; then
      KUBE=oc
    else
      echo "generic"
      return
    fi
  fi
  local labels
  labels=$("$KUBE" get nodes -o go-template='{{range $k,$v := (index .items 0).metadata.labels}}{{$k}}={{$v}}{{"\n"}}{{end}}' 2>/dev/null) || true
  if echo "$labels" | grep -qE '^(agentpool|kubernetes\.azure\.com/agentpool)='; then
    echo "aks"
  elif echo "$labels" | grep -qE '^(eks\.amazonaws\.com/nodegroup|karpenter\.sh/nodepool)='; then
    echo "eks"
  elif echo "$labels" | grep -q '^cloud\.google\.com/gke-nodepool='; then
    echo "gke"
  elif echo "$labels" | grep -qE '^oci\.oraclecloud\.com/(node-pool-id|node\.info\.pool_id)='; then
    echo "oke"
  elif echo "$labels" | grep -qE '^(node\.openshift\.io/os_id|machine\.openshift\.io/cluster-api-machineset)='; then
    echo "ocp"
  else
    echo "generic"
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode)
      MODE="${2:-}"
      shift 2
      ;;
    --no-email)
      NO_EMAIL=1
      shift
      ;;
    --out-dir)
      OUT_DIR="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      NAMESPACES+=("$@")
      break
      ;;
    -*)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
    *)
      NAMESPACES+=("$1")
      shift
      ;;
  esac
done

if [[ ${#NAMESPACES[@]} -eq 0 ]]; then
  usage >&2
  exit 1
fi

case "$MODE" in
  auto|aks-html|multicloud|both) ;;
  *)
    echo "Invalid --mode: $MODE" >&2
    exit 1
    ;;
esac

mkdir -p "$OUT_DIR"

CLOUD_HINT="$(detect_cloud_hint)"
if [[ "$MODE" == "auto" ]]; then
  if [[ "$CLOUD_HINT" == "aks" ]]; then
    MODE="aks-html"
  else
    MODE="multicloud"
  fi
fi

if [[ "$NO_EMAIL" -eq 1 ]]; then
  export SEND_EMAIL=false
fi

TEXT_OUT="${OUT_DIR}/pod_res_util_${TIMESTAMP}.txt"
HTML_OUT="${HTML:-${OUT_DIR}/pod_res_util_${TIMESTAMP}.html}"
SUMMARY_OUT="${OUT_DIR}/pod_res_util_${TIMESTAMP}.summary.md"
RUN_RC=0

echo "============================================================"
echo " POD Resource Utilization Agent (CLI)"
echo "============================================================"
echo "  Mode       : $MODE"
echo "  Cloud hint : $CLOUD_HINT"
echo "  Namespaces : ${NAMESPACES[*]}"
echo "  Out dir    : $OUT_DIR"
echo "  SEND_EMAIL : ${SEND_EMAIL:-true}"
echo "============================================================"
echo ""

run_multicloud() {
  if [[ ! -f "$MULTI_SCRIPT" ]]; then
    echo "ERROR: missing $MULTI_SCRIPT" >&2
    return 1
  fi
  if [[ ! -x "$MULTI_SCRIPT" ]]; then
    chmod +x "$MULTI_SCRIPT" 2>/dev/null || true
  fi
  echo ">>> Running multi-cloud text report..."
  set +e
  bash "$MULTI_SCRIPT" "${NAMESPACES[@]}" 2>&1 | tee "$TEXT_OUT"
  local rc=${PIPESTATUS[0]}
  set -e
  echo ""
  echo "Text report saved: $TEXT_OUT"
  return "$rc"
}

run_aks_html() {
  if [[ ! -f "$AKS_HTML_SCRIPT" ]]; then
    echo "ERROR: missing $AKS_HTML_SCRIPT" >&2
    return 1
  fi
  if [[ ! -x "$AKS_HTML_SCRIPT" ]]; then
    chmod +x "$AKS_HTML_SCRIPT" 2>/dev/null || true
  fi
  echo ">>> Running AKS HTML report..."
  export HTML="$HTML_OUT"
  set +e
  bash "$AKS_HTML_SCRIPT" "${NAMESPACES[@]}"
  local rc=$?
  set -e
  echo ""
  if [[ -f "$HTML_OUT" ]]; then
    echo "HTML report saved: $HTML_OUT"
  else
    echo "WARN: HTML file not found at $HTML_OUT" >&2
  fi
  return "$rc"
}

set +e
case "$MODE" in
  multicloud)
    run_multicloud
    RUN_RC=$?
    ;;
  aks-html)
    run_aks_html
    RUN_RC=$?
    ;;
  both)
    run_multicloud
    local_rc1=$?
    run_aks_html
    local_rc2=$?
    if [[ $local_rc1 -ne 0 || $local_rc2 -ne 0 ]]; then
      RUN_RC=1
    fi
    ;;
esac
set -e

{
  echo "# POD Resource Utilization — run summary"
  echo ""
  echo "- **Timestamp:** $(date '+%Y-%m-%d %H:%M:%S %Z')"
  echo "- **Mode:** $MODE"
  echo "- **Cloud hint:** $CLOUD_HINT"
  echo "- **Namespaces:** ${NAMESPACES[*]}"
  echo "- **Exit code:** $RUN_RC"
  [[ -f "$TEXT_OUT" ]] && echo "- **Text report:** \`$TEXT_OUT\`"
  [[ -f "$HTML_OUT" ]] && echo "- **HTML report:** \`$HTML_OUT\`"
  echo ""
  echo "## Next steps"
  echo "1. Review pool pressure / pending pods / top wasters in the report."
  echo "2. For AI analysis, run: \`npm run agent -- --analyze $TEXT_OUT\` (from \`agent/\`)."
  echo "3. Or ask the Cursor IDE agent using the **pod-res-util** skill."
} > "$SUMMARY_OUT"

echo ""
echo "Summary: $SUMMARY_OUT"
echo "Done (exit=$RUN_RC)."
exit "$RUN_RC"
