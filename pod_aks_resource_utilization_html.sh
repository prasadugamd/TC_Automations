#!/bin/bash
# ============================================================================
#  pod_resource_utilization_html.sh
# ----------------------------------------------------------------------------
#  Owner       : Prasadu Gamini
#  Contact     : prasadu.gamini@extern.A1.at | Prasadu.Gamini@amdocs.com
#  Project     : A1 Austria - TC Kubernetes POD Resource Utilization Report
#  Description : Generates a styled HTML report of AgentPool CPU/Memory
#                utilization (Reserved vs In-Use vs Schedulable vs Idle),
#                pool pressure alerts, pending pods, and top over-provisioned
#                containers with suggested request values.
#                Optionally emails the report via sendmail / mailx.
#  Depends on  : kubectl (with access to target cluster), kubectl top,
#                sendmail OR mailx OR mail (for email delivery).
# ============================================================================
# Usage:
#   ./pod_resource_utilization_html.sh <namespace1> [<namespace2> ...]
#   HTML=/path/to/out.html ./pod_resource_utilization_html.sh pet01-k8s
#   DRY_RUN=true ./pod_resource_utilization_html.sh pet01-k8s            # generate but don't send
#   SEND_EMAIL=false ./pod_resource_utilization_html.sh pet01-k8s        # never email
#   PRESSURE_THRESHOLD_PCT=25 TOP_WASTERS=25 ./pod_resource_utilization_html.sh pet01-k8s
#   ENV_NAME=PROD MAIL_TO="ops@example.com" ./pod_resource_utilization_html.sh pet01-k8s

SCRIPT_OWNER="Prasadu Gamini"
SCRIPT_OWNER_EMAIL="prasadu.gamini@extern.A1.at"

if [ $# -lt 1 ]; then
  echo "Usage: $0 <namespace1> [<namespace2> ... <namespaceN>]" >&2
  exit 1
fi

NAMESPACES=("$@")

# === A1PROD_DEFAULTS_v1 ===
ENV_NAME="${ENV_NAME:-${NAMESPACES[0]}}"
MAIL_FROM="${MAIL_FROM:-prasadu.gamini@extern.A1.at}"
MAIL_TO="${MAIL_TO:-prasadu.gamini@extern.A1.at;branislav.kanocz@extern.a1.at;branislav.kanocz@amdocs.com;Prasadu.Gamini@amdocs.com}"
MAIL_SUBJECT_PREFIX="${MAIL_SUBJECT_PREFIX:-[TC ${ENV_NAME}] A1 Austria POD RESOURCE UTIL Report}"
DRY_RUN="${DRY_RUN:-false}"
SEND_EMAIL="${SEND_EMAIL:-true}"
HR_START="$(date '+%Y-%m-%d %H:%M %Z')"
HTML="${HTML:-/tmp/pod_res_util_$(date +%Y%m%d_%H%M%S).html}"
OVERALL="OK"

log(){ echo "[$(date '+%H:%M:%S')] $*" >&2; }
declare -A POOL_ALLOC_CPU_M
declare -A POOL_USED_CPU_M
declare -A POOL_ALLOC_MEM_MI
declare -A POOL_USED_MEM_MI
declare -A POOL_LIMIT_CPU_M
declare -A POOL_LIMIT_MEM_MI
declare -A POOL_REQ_CPU_M
declare -A POOL_REQ_MEM_MI
declare -A POOL_SEEN
declare -A TARGET_POOLS
declare -A NODE_POOL_CACHE
declare -A POD_WORKLOAD
declare -A POD_REPLICAS
declare -A POD_POOL
declare -a WASTE_ROWS
declare -a PENDING_ROWS
PRESSURE_THRESHOLD_PCT=${PRESSURE_THRESHOLD_PCT:-20}
TOP_WASTERS=${TOP_WASTERS:-15}

cpu_to_m() {
  local value="$1"
  if [[ -z "$value" || "$value" == "<none>" ]]; then
    echo ""
    return
  fi
  if [[ "$value" =~ ^([0-9]+)m$ ]]; then
    echo "${BASH_REMATCH[1]}"
  elif [[ "$value" =~ ^([0-9]+)$ ]]; then
    echo "$(( ${BASH_REMATCH[1]} * 1000 ))"
  else
    echo ""
  fi
}

mem_to_mi() {
  local value="$1"
  if [[ -z "$value" || "$value" == "<none>" ]]; then
    echo ""
    return
  fi
  local number unit
  number=$(echo "$value" | sed -E 's/^([0-9]+).*/\1/')
  unit=$(echo "$value" | sed -E 's/^[0-9]+([A-Za-z]*)$/\1/')
  case "$unit" in
    Ki) echo $(( number / 1024 )) ;;
    Mi|"") echo "$number" ;;
    Gi) echo $(( number * 1024 )) ;;
    Ti) echo $(( number * 1024 * 1024 )) ;;
    *) echo "" ;;
  esac
}

format_cpu_m() {
  local value="$1"
  local core_whole core_frac
  if [[ -z "$value" ]]; then
    echo "N/A"
    return
  fi
  if (( value >= 1000 )); then
    core_whole=$(( value / 1000 ))
    core_frac=$(( (value * 10 / 1000) % 10 ))
    echo "${core_whole}.${core_frac}"
  else
    echo "${value}m"
  fi
}

format_mem_mi() {
  local value="$1"
  local gi_whole gi_frac
  if [[ -z "$value" ]]; then
    echo "N/A"
    return
  fi
  if (( value >= 1024 )); then
    gi_whole=$(( value / 1024 ))
    gi_frac=$(( (value * 10 / 1024) % 10 ))
    echo "${gi_whole}.${gi_frac}Gi"
  else
    echo "${value}Mi"
  fi
}

html_escape() {
  local s="$1"
  s="${s//&/&amp;}"
  s="${s//</&lt;}"
  s="${s//>/&gt;}"
  s="${s//\"/&quot;}"
  echo "$s"
}

suggest_cpu_m() {
  local usage_m="$1"
  local request_m="$2"
  local padded rounded
  if [[ -z "$usage_m" ]]; then
    echo ""
    return
  fi
  padded=$(( usage_m * 3 / 2 ))
  rounded=$(( (padded + 49) / 50 * 50 ))
  (( rounded < 50 )) && rounded=50
  if [[ -n "$request_m" && "$rounded" -gt "$request_m" ]]; then
    rounded="$request_m"
  fi
  echo "$rounded"
}

suggest_mem_mi() {
  local usage_mi="$1"
  local request_mi="$2"
  local padded rounded
  if [[ -z "$usage_mi" ]]; then
    echo ""
    return
  fi
  padded=$(( usage_mi * 13 / 10 ))
  rounded=$(( (padded + 127) / 128 * 128 ))
  (( rounded < 128 )) && rounded=128
  if [[ -n "$request_mi" && "$rounded" -gt "$request_mi" ]]; then
    rounded="$request_mi"
  fi
  echo "$rounded"
}

get_node_pool() {
  local node="$1"
  local pool_data pool_label alt_pool_label pool
  if [[ -n "${NODE_POOL_CACHE["$node"]}" ]]; then
    echo "${NODE_POOL_CACHE["$node"]}"
    return
  fi
  pool_data=$(kubectl get node "$node" -o jsonpath='{.metadata.labels.agentpool}{"|"}{.metadata.labels.kubernetes\.azure\.com/agentpool}' 2>/dev/null)
  pool_label=${pool_data%%|*}
  alt_pool_label=${pool_data##*|}
  pool="$pool_label"
  [[ -z "$pool" ]] && pool="$alt_pool_label"
  [[ -z "$pool" ]] && pool="unassigned"
  NODE_POOL_CACHE["$node"]="$pool"
  echo "$pool"
}

collect_target_agentpools() {
  local namespace node_list node pool
  for namespace in "${NAMESPACES[@]}"; do
    node_list=$(kubectl get pods -n "$namespace" -o jsonpath='{range .items[*]}{.spec.nodeName}{"\n"}{end}' 2>/dev/null | sort -u)
    while IFS= read -r node; do
      [[ -z "$node" ]] && continue
      pool=$(get_node_pool "$node")
      TARGET_POOLS["$pool"]=1
    done <<< "$node_list"
  done
}

collect_workload_replicas() {
  local namespace="$1"
  local name replicas owner_kind owner_name pod_name rs_name
  declare -A deploy_replicas sts_replicas ds_desired rs_to_deploy

  while IFS='|' read -r name replicas; do
    [[ -z "$name" ]] && continue
    deploy_replicas["$name"]="${replicas:-1}"
  done < <(kubectl get deployments -n "$namespace" -o jsonpath='{range .items[*]}{.metadata.name}{"|"}{.spec.replicas}{"\n"}{end}' 2>/dev/null)

  while IFS='|' read -r name replicas; do
    [[ -z "$name" ]] && continue
    sts_replicas["$name"]="${replicas:-1}"
  done < <(kubectl get statefulsets -n "$namespace" -o jsonpath='{range .items[*]}{.metadata.name}{"|"}{.spec.replicas}{"\n"}{end}' 2>/dev/null)

  while IFS='|' read -r name replicas; do
    [[ -z "$name" ]] && continue
    ds_desired["$name"]="${replicas:-1}"
  done < <(kubectl get daemonsets -n "$namespace" -o jsonpath='{range .items[*]}{.metadata.name}{"|"}{.status.desiredNumberScheduled}{"\n"}{end}' 2>/dev/null)

  while IFS='|' read -r rs_name owner_kind owner_name; do
    [[ -z "$rs_name" ]] && continue
    [[ "$owner_kind" == "Deployment" ]] && rs_to_deploy["$rs_name"]="$owner_name"
  done < <(kubectl get replicasets -n "$namespace" -o jsonpath='{range .items[*]}{.metadata.name}{"|"}{.metadata.ownerReferences[0].kind}{"|"}{.metadata.ownerReferences[0].name}{"\n"}{end}' 2>/dev/null)

  local workload replica_count parent_deploy
  while IFS='|' read -r pod_name owner_kind owner_name; do
    [[ -z "$pod_name" ]] && continue
    workload=""
    replica_count=1
    case "$owner_kind" in
      ReplicaSet)
        parent_deploy="${rs_to_deploy[$owner_name]}"
        if [[ -n "$parent_deploy" ]]; then
          workload="Deployment/$parent_deploy"
          replica_count="${deploy_replicas[$parent_deploy]:-1}"
        else
          workload="ReplicaSet/$owner_name"
        fi
        ;;
      StatefulSet)
        workload="StatefulSet/$owner_name"
        replica_count="${sts_replicas[$owner_name]:-1}"
        ;;
      DaemonSet)
        workload="DaemonSet/$owner_name"
        replica_count="${ds_desired[$owner_name]:-1}"
        ;;
      Job)
        workload="Job/$owner_name"
        ;;
      "")
        workload="Pod/$pod_name"
        ;;
      *)
        workload="${owner_kind}/${owner_name}"
        ;;
    esac
    POD_WORKLOAD["$namespace/$pod_name"]="$workload"
    POD_REPLICAS["$namespace/$pod_name"]="$replica_count"
  done < <(kubectl get pods -n "$namespace" -o jsonpath='{range .items[*]}{.metadata.name}{"|"}{.metadata.ownerReferences[0].kind}{"|"}{.metadata.ownerReferences[0].name}{"\n"}{end}' 2>/dev/null)
}

collect_pod_pools() {
  local namespace pod_name node
  for namespace in "${NAMESPACES[@]}"; do
    while IFS='|' read -r pod_name node; do
      [[ -z "$pod_name" || -z "$node" ]] && continue
      POD_POOL["$namespace/$pod_name"]=$(get_node_pool "$node")
    done < <(kubectl get pods -n "$namespace" -o jsonpath='{range .items[*]}{.metadata.name}{"|"}{.spec.nodeName}{"\n"}{end}' 2>/dev/null)
  done
}

collect_pool_workload_totals() {
  local namespace pod_data pod_record pod_name node resource_blob pool
  local container_entry req_cpu req_mem lim_cpu lim_mem
  local req_cpu_m req_mem_mi lim_cpu_m lim_mem_mi
  local pod_req_cpu_m pod_req_mem_mi pod_lim_cpu_m pod_lim_mem_mi
  local workload replicas rest
  declare -A processed_workloads

  for namespace in "${NAMESPACES[@]}"; do
    pod_data=$(kubectl get pods -n "$namespace" -o jsonpath='{range .items[*]}{.metadata.name}{"|"}{.spec.nodeName}{"|"}{range .spec.containers[*]}{@.resources.requests.cpu}{","}{@.resources.requests.memory}{","}{@.resources.limits.cpu}{","}{@.resources.limits.memory}{";"}{end}{"\n"}{end}' 2>/dev/null)

    while IFS= read -r pod_record; do
      pod_name=${pod_record%%|*}
      rest=${pod_record#*|}
      node=${rest%%|*}
      resource_blob=${rest#*|}
      [[ -z "$pod_name" || -z "$node" ]] && continue

      workload="${POD_WORKLOAD["$namespace/$pod_name"]:-Pod/$pod_name}"
      [[ -n "${processed_workloads["$namespace/$workload"]}" ]] && continue
      processed_workloads["$namespace/$workload"]=1

      replicas="${POD_REPLICAS["$namespace/$pod_name"]:-1}"
      pool=$(get_node_pool "$node")

      pod_req_cpu_m=0; pod_req_mem_mi=0; pod_lim_cpu_m=0; pod_lim_mem_mi=0

      IFS=';' read -ra container_entries <<< "$resource_blob"
      for container_entry in "${container_entries[@]}"; do
        [[ -z "$container_entry" ]] && continue
        IFS=',' read -r req_cpu req_mem lim_cpu lim_mem <<< "$container_entry"
        req_cpu_m=$(cpu_to_m "$req_cpu")
        req_mem_mi=$(mem_to_mi "$req_mem")
        lim_cpu_m=$(cpu_to_m "$lim_cpu")
        lim_mem_mi=$(mem_to_mi "$lim_mem")
        [[ -n "$req_cpu_m" ]] && pod_req_cpu_m=$(( pod_req_cpu_m + req_cpu_m ))
        [[ -n "$req_mem_mi" ]] && pod_req_mem_mi=$(( pod_req_mem_mi + req_mem_mi ))
        [[ -n "$lim_cpu_m" ]] && pod_lim_cpu_m=$(( pod_lim_cpu_m + lim_cpu_m ))
        [[ -n "$lim_mem_mi" ]] && pod_lim_mem_mi=$(( pod_lim_mem_mi + lim_mem_mi ))
      done

      POOL_REQ_CPU_M["$pool"]=$(( ${POOL_REQ_CPU_M["$pool"]:-0} + pod_req_cpu_m * replicas ))
      POOL_REQ_MEM_MI["$pool"]=$(( ${POOL_REQ_MEM_MI["$pool"]:-0} + pod_req_mem_mi * replicas ))
      POOL_LIMIT_CPU_M["$pool"]=$(( ${POOL_LIMIT_CPU_M["$pool"]:-0} + pod_lim_cpu_m * replicas ))
      POOL_LIMIT_MEM_MI["$pool"]=$(( ${POOL_LIMIT_MEM_MI["$pool"]:-0} + pod_lim_mem_mi * replicas ))
    done <<< "$pod_data"
  done
}

collect_node_allocatable_and_usage() {
  local node_resource_data node_usage_data node pool_label alt_pool_label pool
  local alloc_cpu alloc_mem alloc_cpu_m alloc_mem_mi
  local usage_fields used_cpu used_mem used_cpu_m used_mem_mi

  node_resource_data=$(kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"|"}{.metadata.labels.agentpool}{"|"}{.metadata.labels.kubernetes\.azure\.com/agentpool}{"|"}{.status.allocatable.cpu}{"|"}{.status.allocatable.memory}{"\n"}{end}' 2>/dev/null)
  node_usage_data=$(kubectl top nodes --no-headers 2>/dev/null)

  while IFS='|' read -r node pool_label alt_pool_label alloc_cpu alloc_mem; do
    [[ -z "$node" ]] && continue
    pool="$pool_label"
    [[ -z "$pool" ]] && pool="$alt_pool_label"
    [[ -z "$pool" ]] && pool="unassigned"
    POOL_SEEN["$pool"]=1

    alloc_cpu_m=$(cpu_to_m "$alloc_cpu")
    alloc_mem_mi=$(mem_to_mi "$alloc_mem")
    [[ -n "$alloc_cpu_m" ]] && POOL_ALLOC_CPU_M["$pool"]=$(( ${POOL_ALLOC_CPU_M["$pool"]:-0} + alloc_cpu_m ))
    [[ -n "$alloc_mem_mi" ]] && POOL_ALLOC_MEM_MI["$pool"]=$(( ${POOL_ALLOC_MEM_MI["$pool"]:-0} + alloc_mem_mi ))

    usage_fields=$(echo "$node_usage_data" | awk -v node_name="$node" '$1==node_name {print $2 "|" $4; exit}')
    used_cpu=${usage_fields%%|*}
    used_mem=${usage_fields##*|}
    used_cpu_m=$(cpu_to_m "$used_cpu")
    used_mem_mi=$(mem_to_mi "$used_mem")
    [[ -n "$used_cpu_m" ]] && POOL_USED_CPU_M["$pool"]=$(( ${POOL_USED_CPU_M["$pool"]:-0} + used_cpu_m ))
    [[ -n "$used_mem_mi" ]] && POOL_USED_MEM_MI["$pool"]=$(( ${POOL_USED_MEM_MI["$pool"]:-0} + used_mem_mi ))
  done <<< "$node_resource_data"
}

collect_pending_pods() {
  local namespace pod_record pod_name phase resource_blob
  local container_entry req_cpu req_mem
  local req_cpu_m req_mem_mi pod_req_cpu_m pod_req_mem_mi
  local reason rest

  for namespace in "${NAMESPACES[@]}"; do
    while IFS= read -r pod_record; do
      pod_name=${pod_record%%|*}
      rest=${pod_record#*|}
      phase=${rest%%|*}
      resource_blob=${rest#*|}
      [[ -z "$pod_name" || "$phase" != "Pending" ]] && continue

      pod_req_cpu_m=0
      pod_req_mem_mi=0
      IFS=';' read -ra container_entries <<< "$resource_blob"
      for container_entry in "${container_entries[@]}"; do
        [[ -z "$container_entry" ]] && continue
        IFS=',' read -r req_cpu req_mem <<< "$container_entry"
        req_cpu_m=$(cpu_to_m "$req_cpu")
        req_mem_mi=$(mem_to_mi "$req_mem")
        [[ -n "$req_cpu_m" ]] && pod_req_cpu_m=$(( pod_req_cpu_m + req_cpu_m ))
        [[ -n "$req_mem_mi" ]] && pod_req_mem_mi=$(( pod_req_mem_mi + req_mem_mi ))
      done

      reason=$(kubectl get event -n "$namespace" --field-selector involvedObject.name="$pod_name",reason=FailedScheduling -o jsonpath='{.items[-1:].message}' 2>/dev/null | head -c 240)
      [[ -z "$reason" ]] && reason="(no FailedScheduling event)"
      PENDING_ROWS+=("$namespace|$pod_name|$pod_req_cpu_m|$pod_req_mem_mi|$reason")
    done < <(kubectl get pods -n "$namespace" -o jsonpath='{range .items[*]}{.metadata.name}{"|"}{.status.phase}{"|"}{range .spec.containers[*]}{@.resources.requests.cpu}{","}{@.resources.requests.memory}{";"}{end}{"\n"}{end}' 2>/dev/null)
  done
}

collect_waste_rows() {
  local namespace pods pod containers container container_name
  local request_cpu request_memory limit_cpu limit_memory
  local cpu_usage mem_usage req_cpu_m req_mem_mi cpu_usage_m usage_mem_mi
  local waste_cpu_m waste_mem_mi pod_pool pod_usage

  for namespace in "${NAMESPACES[@]}"; do
    pods=$(kubectl get pods -n "$namespace" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)
    for pod in $pods; do
      pod_usage=$(kubectl top pod "$pod" -n "$namespace" --containers 2>/dev/null)
      containers=$(kubectl get pod "$pod" -n "$namespace" -o jsonpath='{range .spec.containers[*]}{@.name} {@.resources.requests.cpu} {@.resources.requests.memory} {@.resources.limits.cpu} {@.resources.limits.memory}{"\n"}{end}' 2>/dev/null)
      while IFS= read -r container; do
        container_name=$(echo "$container" | awk '{print $1}')
        request_cpu=$(echo "$container" | awk '{print $2}')
        request_memory=$(echo "$container" | awk '{print $3}')
        limit_cpu=$(echo "$container" | awk '{print $4}')
        limit_memory=$(echo "$container" | awk '{print $5}')
        cpu_usage=$(echo "$pod_usage" | grep -w "$container_name\s" | awk '{print $3}')
        mem_usage=$(echo "$pod_usage" | grep -w "$container_name\s" | awk '{print $4}')

        req_cpu_m=$(cpu_to_m "$request_cpu")
        req_mem_mi=$(mem_to_mi "$request_memory")
        cpu_usage_m=$(cpu_to_m "$cpu_usage")
        usage_mem_mi=$(mem_to_mi "$mem_usage")

        waste_cpu_m=0
        waste_mem_mi=0
        if [[ -n "$req_cpu_m" && -n "$cpu_usage_m" && "$req_cpu_m" -gt "$cpu_usage_m" ]]; then
          waste_cpu_m=$(( req_cpu_m - cpu_usage_m ))
        fi
        if [[ -n "$req_mem_mi" && -n "$usage_mem_mi" && "$req_mem_mi" -gt "$usage_mem_mi" ]]; then
          waste_mem_mi=$(( req_mem_mi - usage_mem_mi ))
        fi
        if [[ ( -n "$req_cpu_m" && -n "$cpu_usage_m" ) || ( -n "$req_mem_mi" && -n "$usage_mem_mi" ) ]]; then
          pod_pool="${POD_POOL["$namespace/$pod"]:-unknown}"
          WASTE_ROWS+=("${waste_cpu_m}|${waste_mem_mi}|${namespace}|${pod}|${container_name}|${req_cpu_m:-0}|${cpu_usage_m:-0}|${req_mem_mi:-0}|${usage_mem_mi:-0}|${pod_pool}")
        fi
      done <<< "$containers"
    done
  done
}

# ---------- overall status ----------

compute_overall_status() {
  local pool alloc_cpu req_cpu used_cpu alloc_mem req_mem used_mem
  local sched_cpu_pct sched_mem_pct live_cpu_pct live_mem_pct
  local sched_tight_cpu sched_tight_mem live_tight_cpu live_tight_mem
  local has_critical=0 has_warn=0

  for pool in "${!POOL_SEEN[@]}"; do
    [[ -z "${TARGET_POOLS["$pool"]}" ]] && continue
    alloc_cpu=${POOL_ALLOC_CPU_M["$pool"]:-0}
    req_cpu=${POOL_REQ_CPU_M["$pool"]:-0}
    used_cpu=${POOL_USED_CPU_M["$pool"]:-0}
    alloc_mem=${POOL_ALLOC_MEM_MI["$pool"]:-0}
    req_mem=${POOL_REQ_MEM_MI["$pool"]:-0}
    used_mem=${POOL_USED_MEM_MI["$pool"]:-0}

    sched_cpu_pct=100; sched_mem_pct=100; live_cpu_pct=100; live_mem_pct=100
    (( alloc_cpu > 0 )) && sched_cpu_pct=$(( (alloc_cpu - req_cpu) * 100 / alloc_cpu ))
    (( alloc_mem > 0 )) && sched_mem_pct=$(( (alloc_mem - req_mem) * 100 / alloc_mem ))
    (( alloc_cpu > 0 )) && live_cpu_pct=$((  (alloc_cpu - used_cpu) * 100 / alloc_cpu ))
    (( alloc_mem > 0 )) && live_mem_pct=$((  (alloc_mem - used_mem) * 100 / alloc_mem ))

    sched_tight_cpu=0; (( sched_cpu_pct < PRESSURE_THRESHOLD_PCT )) && sched_tight_cpu=1
    sched_tight_mem=0; (( sched_mem_pct < PRESSURE_THRESHOLD_PCT )) && sched_tight_mem=1
    live_tight_cpu=0;  (( live_cpu_pct  < PRESSURE_THRESHOLD_PCT )) && live_tight_cpu=1
    live_tight_mem=0;  (( live_mem_pct  < PRESSURE_THRESHOLD_PCT )) && live_tight_mem=1

    if (( ( sched_tight_cpu && live_tight_cpu ) || ( sched_tight_mem && live_tight_mem ) )); then
      has_critical=1
    elif (( sched_tight_cpu || sched_tight_mem || live_tight_cpu || live_tight_mem )); then
      has_warn=1
    fi
  done

  [[ ${#PENDING_ROWS[@]} -gt 0 ]] && has_warn=1

  if (( has_critical )); then
    OVERALL="CRITICAL"
  elif (( has_warn )); then
    OVERALL="WARN"
  else
    OVERALL="OK"
  fi
}

# ---------- email ----------

_find_sendmail_bin() {
  local cand
  for cand in /usr/sbin/sendmail /usr/lib/sendmail /usr/sbin/msmtp /usr/local/sbin/sendmail sendmail msmtp; do
    if [[ -x "$cand" ]]; then
      echo "$cand"; return 0
    fi
    if command -v "$cand" >/dev/null 2>&1; then
      command -v "$cand"; return 0
    fi
  done
  return 1
}

send_email() {
  if [[ "$SEND_EMAIL" != "true" ]]; then
    log "SEND_EMAIL=$SEND_EMAIL: skipping email. HTML at $HTML"
    return 0
  fi
  if [[ "$DRY_RUN" == "true" ]]; then
    log "Dry-run: skipping email. HTML at $HTML"
    return 0
  fi

  local subject="${MAIL_SUBJECT_PREFIX} - ${HR_START} - ${OVERALL}"
  local to_list="${MAIL_TO//;/,}"
  local rc=1
  local sendmail_bin

  # 1) Try sendmail / msmtp anywhere on the box (not just PATH)
  if sendmail_bin=$(_find_sendmail_bin); then
    {
      echo "From: TC POD RES UTIL Report <${MAIL_FROM}>"
      echo "To: ${to_list}"
      echo "Subject: ${subject}"
      echo "MIME-Version: 1.0"
      echo "Content-Type: text/html; charset=UTF-8"
      echo "Content-Transfer-Encoding: 8bit"
      echo
      cat "$HTML"
    } | "$sendmail_bin" -t -f "$MAIL_FROM" 2>/dev/null
    rc=$?
    if (( rc == 0 )); then
      log "Email sent via $sendmail_bin to $to_list (subject: $subject)"
      return 0
    fi
    log "$sendmail_bin returned rc=$rc, trying mailx fallback"
  fi

  # 2) mailx fallback: try multiple variants (Heirloom / s-nail / GNU mailutils)
  #    IMPORTANT: mailx writes ~/dead.letter when delivery fails but often still
  #    exits with rc=0. We treat any dead.letter created / rewritten during the
  #    call as a silent-failure signal and fall through to the next method.
  #    Detection uses BOTH size and mtime because two mailx calls within the
  #    same wall-clock second can share an mtime but will differ in size.
  local dead_letter="${HOME:-/tmp}/dead.letter"
  local dl_sig_before dl_sig_after
  _dead_letter_sig() {
    if [[ -f "$dead_letter" ]]; then
      stat -c '%Y-%s' "$dead_letter" 2>/dev/null \
        || stat -f '%m-%z' "$dead_letter" 2>/dev/null \
        || echo "exists-$(wc -c < "$dead_letter" 2>/dev/null)"
    else
      echo "__missing__"
    fi
  }
  _dead_letter_snapshot() { dl_sig_before=$(_dead_letter_sig); }
  _dead_letter_bumped()   { dl_sig_after=$(_dead_letter_sig); [[ "$dl_sig_before" != "$dl_sig_after" ]]; }

  if command -v mailx >/dev/null 2>&1; then
    # 2a) Heirloom/s-nail style: -a "Header: value"
    _dead_letter_snapshot
    mailx -a "Content-Type: text/html; charset=UTF-8" \
          -a "MIME-Version: 1.0" \
          -s "$subject" -r "$MAIL_FROM" "$to_list" < "$HTML" 2>/dev/null
    rc=$?
    if (( rc == 0 )) && ! _dead_letter_bumped; then
      log "Email sent via mailx (Heirloom-style) to $to_list"
      return 0
    fi
    _dead_letter_bumped && log "mailx (Heirloom-style) silently failed (dead.letter created)"

    # 2b) s-nail style: -S content-type=...
    _dead_letter_snapshot
    mailx -S "content-type=text/html; charset=UTF-8" \
          -s "$subject" -r "$MAIL_FROM" "$to_list" < "$HTML" 2>/dev/null
    rc=$?
    if (( rc == 0 )) && ! _dead_letter_bumped; then
      log "Email sent via mailx (-S content-type) to $to_list"
      return 0
    fi
    _dead_letter_bumped && log "mailx (-S content-type) silently failed (dead.letter created)"

    # 2c) GNU mailutils style: prepend MIME headers to the body itself
    _dead_letter_snapshot
    {
      echo "MIME-Version: 1.0"
      echo "Content-Type: text/html; charset=UTF-8"
      echo "Content-Transfer-Encoding: 8bit"
      echo
      cat "$HTML"
    } | mailx -s "$subject" -r "$MAIL_FROM" "$to_list" 2>/dev/null
    rc=$?
    if (( rc == 0 )) && ! _dead_letter_bumped; then
      log "Email sent via mailx (GNU MIME-in-body) to $to_list"
      return 0
    fi
    _dead_letter_bumped && log "mailx (GNU MIME-in-body) silently failed (dead.letter created)"

    log "mailx: all three fallback variants failed (last rc=$rc)"
    if [[ -f "$dead_letter" ]]; then
      log "Undelivered mail preserved at $dead_letter (mailx has no working SMTP relay on this host)"
    fi
  fi

  # 3) Last resort: try /bin/mail
  if command -v mail >/dev/null 2>&1; then
    {
      echo "MIME-Version: 1.0"
      echo "Content-Type: text/html; charset=UTF-8"
      echo "Content-Transfer-Encoding: 8bit"
      echo
      cat "$HTML"
    } | mail -s "$subject" "$to_list" 2>/dev/null
    rc=$?
    if (( rc == 0 )); then
      log "Email sent via mail (last-resort) to $to_list"
      return 0
    fi
  fi

  log "ERROR: no working mail tool. HTML preserved at $HTML"
  log "Diagnose with:"
  log "  which sendmail mailx msmtp mail   # what's installed"
  log "  ls -la $HOME/dead.letter          # last undelivered message (if any)"
  log "  tail -50 /var/log/maillog         # local MTA log, if present"
  log "Fixes:"
  log "  (a) install sendmail: sudo yum install sendmail-cf   /   sudo apt install sendmail"
  log "  (b) install msmtp:    sudo yum install msmtp         /   sudo apt install msmtp"
  log "  (c) configure a smart-host / SMTP relay in /etc/mail/sendmail.mc or ~/.msmtprc"
  log "  (d) run with SEND_EMAIL=false to disable email and just generate the HTML file"
  return 1
}

# ---------- HTML emitters ----------

emit_html_header() {
  local generated_at ns_list overall_class
  generated_at=$(date '+%Y-%m-%d %H:%M:%S %Z')
  ns_list=$(html_escape "${NAMESPACES[*]}")
  case "$OVERALL" in
    CRITICAL) overall_class="badge badge-critical" ;;
    WARN)     overall_class="badge badge-warn" ;;
    *)        overall_class="badge badge-ok" ;;
  esac
  cat <<HTMLEOF
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<title>Pod Resource Utilization Report - ${ns_list}</title>
<style>
  * { box-sizing: border-box; }
  body { font-family: -apple-system, "Segoe UI", Roboto, Helvetica, Arial, sans-serif; margin: 24px; color: #1f2328; background: #f6f8fa; }
  h1 { color: #0969da; border-bottom: 3px solid #0969da; padding-bottom: 8px; margin-bottom: 4px; }
  h2 { color: #0550ae; margin-top: 32px; margin-bottom: 8px; }
  .meta { color: #57606a; font-size: 13px; margin-bottom: 24px; }
  .section { background: #ffffff; border: 1px solid #d0d7de; border-radius: 8px; padding: 16px 20px; margin-bottom: 20px; }
  .section-note { color: #57606a; font-size: 12px; margin-top: 8px; line-height: 1.5; }
  .section-note code { background: #eff2f5; padding: 1px 5px; border-radius: 3px; font-size: 12px; }
  table { border-collapse: collapse; width: 100%; font-size: 13px; margin-top: 8px; }
  th { background: #f6f8fa; border: 1px solid #d0d7de; padding: 8px 10px; text-align: left; font-weight: 600; color: #24292f; position: sticky; top: 0; }
  td { border: 1px solid #d0d7de; padding: 6px 10px; vertical-align: middle; }
  tr:nth-child(even) td { background: #fbfcfe; }
  tr:hover td { background: #fff8c5; }
  .num { text-align: right; font-variant-numeric: tabular-nums; font-family: "SF Mono", Consolas, monospace; }
  .mono { font-family: "SF Mono", Consolas, monospace; font-size: 12px; }
  .pool { font-weight: 600; color: #0550ae; }
  .badge { display: inline-block; padding: 2px 8px; border-radius: 10px; font-size: 11px; font-weight: 600; }
  .badge-critical { background: #ffebe9; color: #cf222e; border: 1px solid #ff818244; }
  .badge-warn { background: #fff8c5; color: #9a6700; border: 1px solid #d4a72c66; }
  .badge-hot { background: #ffe0f0; color: #a83274; border: 1px solid #ea6dad66; }
  .badge-ok { background: #dafbe1; color: #1a7f37; border: 1px solid #4ac26b66; }
  .waste-heavy { color: #cf222e; font-weight: 600; }
  .waste-med { color: #9a6700; font-weight: 500; }
  .waste-light { color: #57606a; }
  .empty-row td { text-align: center; color: #57606a; font-style: italic; }
  .footnotes { color: #57606a; font-size: 12px; margin-top: 30px; line-height: 1.6; }
  .footnotes ul { margin: 4px 0 0 20px; padding: 0; }
</style>
</head>
<body>
<h1>Kubernetes Pod Resource Utilization Report</h1>
<div class="meta">
  Overall: <span class="${overall_class}">${OVERALL}</span> &middot;
  Environment: <strong>${ENV_NAME}</strong> &middot;
  Generated: <strong>${generated_at}</strong> &middot;
  Namespaces: <strong>${ns_list}</strong> &middot;
  Pressure threshold: <strong>${PRESSURE_THRESHOLD_PCT}%</strong> &middot;
  Top wasters: <strong>${TOP_WASTERS}</strong>
</div>
HTMLEOF
}

emit_html_footer() {
  local owner_html owner_email_html
  owner_html=$(html_escape "$SCRIPT_OWNER")
  owner_email_html=$(html_escape "$SCRIPT_OWNER_EMAIL")
  cat <<HTMLEOF
<div class="footnotes">
  <strong>Notes</strong>
  <ul>
    <li><em>Suggested Req</em> = usage &times; 1.5 (CPU) or &times; 1.3 (Memory), rounded up, capped at current request.</li>
    <li>Suggestions are based on a single <code>kubectl top</code> sample. For steady-state pods this is fine; for bursty workloads, use p95 over 7&ndash;30 days (Prometheus, Azure Monitor, or <code>krr</code>).</li>
    <li>Tune with environment variables: <code>PRESSURE_THRESHOLD_PCT</code> (default 20), <code>TOP_WASTERS</code> (default 15).</li>
    <li><em>Reserved</em> = sum of container requests/limits &times; desired replicas. <em>In-Use</em> = live values from <code>kubectl top nodes</code>.</li>
  </ul>
  <hr style="border:0; border-top:1px solid #d0d7de; margin:16px 0;">
  <div>Report generated by <strong>pod_resource_utilization_html.sh</strong> &middot;
       Owner: <strong>${owner_html}</strong>
       &lt;<a href="mailto:${owner_email_html}">${owner_email_html}</a>&gt;</div>
</div>
</body>
</html>
HTMLEOF
}

emit_agentpool_cpu_summary() {
  local pool alloc req limit used sched_free live_free

  echo '<div class="section">'
  echo '<h2>AgentPool CPU Summary</h2>'
  echo '<table>'
  echo '<thead><tr>'
  echo '<th>AgentPool</th>'
  echo '<th class="num">CPU Capacity</th>'
  echo '<th class="num">CPU Reserved</th>'
  echo '<th class="num">CPU Lim Reserved</th>'
  echo '<th class="num">CPU In-Use</th>'
  echo '<th class="num">CPU Schedulable</th>'
  echo '<th class="num">CPU Idle</th>'
  echo '</tr></thead><tbody>'

  if [[ ${#TARGET_POOLS[@]} -eq 0 ]]; then
    echo '<tr class="empty-row"><td colspan="7">No target agentpools found</td></tr>'
  else
    while IFS= read -r pool; do
      [[ -z "${TARGET_POOLS["$pool"]}" ]] && continue
      alloc=${POOL_ALLOC_CPU_M["$pool"]:-0}
      req=${POOL_REQ_CPU_M["$pool"]:-0}
      limit=${POOL_LIMIT_CPU_M["$pool"]:-0}
      used=${POOL_USED_CPU_M["$pool"]:-0}
      sched_free=$(( alloc - req ))
      live_free=$(( alloc - used ))
      (( sched_free < 0 )) && sched_free=0
      (( live_free  < 0 )) && live_free=0
      printf '<tr><td class="pool">%s</td><td class="num">%s</td><td class="num">%s</td><td class="num">%s</td><td class="num">%s</td><td class="num">%s</td><td class="num">%s</td></tr>\n' \
        "$(html_escape "$pool")" \
        "$(format_cpu_m "$alloc")" \
        "$(format_cpu_m "$req")" \
        "$(format_cpu_m "$limit")" \
        "$(format_cpu_m "$used")" \
        "$(format_cpu_m "$sched_free")" \
        "$(format_cpu_m "$live_free")"
    done < <(printf "%s\n" "${!POOL_SEEN[@]}" | sort)
  fi

  echo '</tbody></table>'
  cat <<'HTMLEOF'
<div class="section-note">
  <strong>CPU Capacity</strong> = total <code>.status.allocatable.cpu</code> across pool nodes &middot;
  <strong>CPU Reserved</strong> = sum of requests &times; desired replicas (what the SCHEDULER counts) &middot;
  <strong>CPU Lim Reserved</strong> = sum of limits &times; desired replicas (may overcommit) &middot;
  <strong>CPU In-Use</strong> = live usage from <code>kubectl top nodes</code> &middot;
  <strong>CPU Schedulable</strong> = Capacity - Reserved (headroom for new pods) &middot;
  <strong>CPU Idle</strong> = Capacity - In-Use (actual free CPU).
</div>
HTMLEOF
  echo '</div>'
}

emit_agentpool_memory_summary() {
  local pool alloc req limit used sched_free live_free

  echo '<div class="section">'
  echo '<h2>AgentPool Memory Summary</h2>'
  echo '<table>'
  echo '<thead><tr>'
  echo '<th>AgentPool</th>'
  echo '<th class="num">Mem Capacity</th>'
  echo '<th class="num">Mem Reserved</th>'
  echo '<th class="num">Mem Lim Reserved</th>'
  echo '<th class="num">Mem In-Use</th>'
  echo '<th class="num">Mem Schedulable</th>'
  echo '<th class="num">Mem Idle</th>'
  echo '</tr></thead><tbody>'

  if [[ ${#TARGET_POOLS[@]} -eq 0 ]]; then
    echo '<tr class="empty-row"><td colspan="7">No target agentpools found</td></tr>'
  else
    while IFS= read -r pool; do
      [[ -z "${TARGET_POOLS["$pool"]}" ]] && continue
      alloc=${POOL_ALLOC_MEM_MI["$pool"]:-0}
      req=${POOL_REQ_MEM_MI["$pool"]:-0}
      limit=${POOL_LIMIT_MEM_MI["$pool"]:-0}
      used=${POOL_USED_MEM_MI["$pool"]:-0}
      sched_free=$(( alloc - req ))
      live_free=$(( alloc - used ))
      (( sched_free < 0 )) && sched_free=0
      (( live_free  < 0 )) && live_free=0
      printf '<tr><td class="pool">%s</td><td class="num">%s</td><td class="num">%s</td><td class="num">%s</td><td class="num">%s</td><td class="num">%s</td><td class="num">%s</td></tr>\n' \
        "$(html_escape "$pool")" \
        "$(format_mem_mi "$alloc")" \
        "$(format_mem_mi "$req")" \
        "$(format_mem_mi "$limit")" \
        "$(format_mem_mi "$used")" \
        "$(format_mem_mi "$sched_free")" \
        "$(format_mem_mi "$live_free")"
    done < <(printf "%s\n" "${!POOL_SEEN[@]}" | sort)
  fi

  echo '</tbody></table>'
  cat <<'HTMLEOF'
<div class="section-note">
  <strong>Mem Capacity</strong> = total <code>.status.allocatable.memory</code> across pool nodes &middot;
  <strong>Mem Reserved</strong> = sum of requests &times; desired replicas &middot;
  <strong>Mem Lim Reserved</strong> = sum of limits &times; desired replicas &middot;
  <strong>Mem In-Use</strong> = live usage from <code>kubectl top nodes</code> &middot;
  <strong>Mem Schedulable</strong> = Capacity - Reserved &middot;
  <strong>Mem Idle</strong> = Capacity - In-Use.
</div>
HTMLEOF
  echo '</div>'
}

emit_pool_pressure_alert() {
  local pool alloc_cpu req_cpu used_cpu alloc_mem req_mem used_mem
  local sched_free_cpu sched_free_mem live_free_cpu live_free_mem
  local sched_cpu_pct sched_mem_pct live_cpu_pct live_mem_pct
  local sched_tight_cpu sched_tight_mem live_tight_cpu live_tight_mem
  local status status_class flagged=0

  echo '<div class="section">'
  echo "<h2>Pool Pressure Alert (threshold ${PRESSURE_THRESHOLD_PCT}%)</h2>"
  echo '<table>'
  echo '<thead><tr>'
  echo '<th>AgentPool</th>'
  echo '<th class="num">CPU Schedulable</th>'
  echo '<th class="num">% CPU Sched</th>'
  echo '<th class="num">CPU Idle</th>'
  echo '<th class="num">% CPU Idle</th>'
  echo '<th class="num">Mem Schedulable</th>'
  echo '<th class="num">% Mem Sched</th>'
  echo '<th class="num">Mem Idle</th>'
  echo '<th class="num">% Mem Idle</th>'
  echo '<th>Status</th>'
  echo '</tr></thead><tbody>'

  while IFS= read -r pool; do
    [[ -z "${TARGET_POOLS["$pool"]}" ]] && continue
    alloc_cpu=${POOL_ALLOC_CPU_M["$pool"]:-0}
    req_cpu=${POOL_REQ_CPU_M["$pool"]:-0}
    used_cpu=${POOL_USED_CPU_M["$pool"]:-0}
    alloc_mem=${POOL_ALLOC_MEM_MI["$pool"]:-0}
    req_mem=${POOL_REQ_MEM_MI["$pool"]:-0}
    used_mem=${POOL_USED_MEM_MI["$pool"]:-0}

    sched_free_cpu=$(( alloc_cpu - req_cpu ))
    sched_free_mem=$(( alloc_mem - req_mem ))
    live_free_cpu=$(( alloc_cpu - used_cpu ))
    live_free_mem=$(( alloc_mem - used_mem ))
    (( sched_free_cpu < 0 )) && sched_free_cpu=0
    (( sched_free_mem < 0 )) && sched_free_mem=0
    (( live_free_cpu  < 0 )) && live_free_cpu=0
    (( live_free_mem  < 0 )) && live_free_mem=0

    sched_cpu_pct=0; sched_mem_pct=0; live_cpu_pct=0; live_mem_pct=0
    (( alloc_cpu > 0 )) && sched_cpu_pct=$(( sched_free_cpu * 100 / alloc_cpu ))
    (( alloc_mem > 0 )) && sched_mem_pct=$(( sched_free_mem * 100 / alloc_mem ))
    (( alloc_cpu > 0 )) && live_cpu_pct=$((  live_free_cpu  * 100 / alloc_cpu ))
    (( alloc_mem > 0 )) && live_mem_pct=$((  live_free_mem  * 100 / alloc_mem ))

    sched_tight_cpu=0; (( sched_cpu_pct < PRESSURE_THRESHOLD_PCT )) && sched_tight_cpu=1
    sched_tight_mem=0; (( sched_mem_pct < PRESSURE_THRESHOLD_PCT )) && sched_tight_mem=1
    live_tight_cpu=0;  (( live_cpu_pct  < PRESSURE_THRESHOLD_PCT )) && live_tight_cpu=1
    live_tight_mem=0;  (( live_mem_pct  < PRESSURE_THRESHOLD_PCT )) && live_tight_mem=1

    if (( sched_tight_cpu == 0 && sched_tight_mem == 0 && live_tight_cpu == 0 && live_tight_mem == 0 )); then
      continue
    fi

    if (( ( sched_tight_cpu && live_tight_cpu ) || ( sched_tight_mem && live_tight_mem ) )); then
      status="CRITICAL - add nodes"
      status_class="badge badge-critical"
    elif (( sched_tight_cpu || sched_tight_mem )); then
      status="RESERVED BUT IDLE - rightsize"
      status_class="badge badge-warn"
    else
      status="HOT - investigate bursts"
      status_class="badge badge-hot"
    fi

    flagged=1
    printf '<tr><td class="pool">%s</td><td class="num">%s</td><td class="num">%d%%</td><td class="num">%s</td><td class="num">%d%%</td><td class="num">%s</td><td class="num">%d%%</td><td class="num">%s</td><td class="num">%d%%</td><td><span class="%s">%s</span></td></tr>\n' \
      "$(html_escape "$pool")" \
      "$(format_cpu_m "$sched_free_cpu")" "$sched_cpu_pct" \
      "$(format_cpu_m "$live_free_cpu")"  "$live_cpu_pct" \
      "$(format_mem_mi "$sched_free_mem")" "$sched_mem_pct" \
      "$(format_mem_mi "$live_free_mem")"  "$live_mem_pct" \
      "$status_class" "$status"
  done < <(printf "%s\n" "${!POOL_SEEN[@]}" | sort)

  if [[ $flagged -eq 0 ]]; then
    echo '<tr class="empty-row"><td colspan="10"><span class="badge badge-ok">All pools OK</span> &nbsp; No pools under pressure.</td></tr>'
  fi

  echo '</tbody></table>'
  cat <<'HTMLEOF'
<div class="section-note">
  <strong>Status legend:</strong><br>
  <span class="badge badge-critical">CRITICAL - add nodes</span> Schedulable AND Idle both low on the same resource; new pods won't fit and nodes are hot &rarr; add capacity.<br>
  <span class="badge badge-warn">RESERVED BUT IDLE - rightsize</span> Schedulable is low but nodes are Idle; trim requests (see Over-Provisioned tables below).<br>
  <span class="badge badge-hot">HOT - investigate bursts</span> Schedulable looks fine but Idle is low; workload is bursting &rarr; check limits/GC/noisy neighbours.
</div>
HTMLEOF
  echo '</div>'
}

emit_pending_pods() {
  local row ns pod req_cpu_m req_mem_mi reason

  echo '<div class="section">'
  echo '<h2>Pending Pods (waiting to schedule)</h2>'
  echo '<table>'
  echo '<thead><tr>'
  echo '<th>Namespace</th>'
  echo '<th>Pod</th>'
  echo '<th class="num">Req CPU</th>'
  echo '<th class="num">Req Memory</th>'
  echo '<th>Reason (last FailedScheduling event)</th>'
  echo '</tr></thead><tbody>'

  if [[ ${#PENDING_ROWS[@]} -eq 0 ]]; then
    echo '<tr class="empty-row"><td colspan="5"><span class="badge badge-ok">All clear</span> &nbsp; No Pending pods found.</td></tr>'
  else
    for row in "${PENDING_ROWS[@]}"; do
      IFS='|' read -r ns pod req_cpu_m req_mem_mi reason <<< "$row"
      printf '<tr><td>%s</td><td class="mono">%s</td><td class="num">%s</td><td class="num">%s</td><td class="mono">%s</td></tr>\n' \
        "$(html_escape "$ns")" \
        "$(html_escape "$pod")" \
        "$(format_cpu_m "$req_cpu_m")" \
        "$(format_mem_mi "$req_mem_mi")" \
        "$(html_escape "$reason")"
    done
  fi

  echo '</tbody></table>'
  echo '</div>'
}

emit_top_wasters() {
  local sort_field="$1"
  local title="$2"
  local resource_label="$3"
  local unit_helper="$4"
  local row waste_cpu waste_mem ns pod container req_cpu use_cpu req_mem use_mem pool suggested
  local shown=0 total_freed=0
  local cell_class

  echo '<div class="section">'
  echo "<h2>${title}</h2>"
  echo '<table>'
  echo '<thead><tr>'
  echo '<th>Pool</th>'
  echo '<th>Namespace</th>'
  echo '<th>Pod</th>'
  echo '<th>Container</th>'
  echo '<th class="num">Request</th>'
  echo '<th class="num">Actual</th>'
  echo '<th class="num">Waste</th>'
  echo '<th class="num">Suggested Req</th>'
  echo '</tr></thead><tbody>'

  if [[ ${#WASTE_ROWS[@]} -eq 0 ]]; then
    echo '<tr class="empty-row"><td colspan="8">No data collected (kubectl top may be unavailable)</td></tr>'
    echo '</tbody></table></div>'
    return
  fi

  while IFS= read -r row; do
    IFS='|' read -r waste_cpu waste_mem ns pod container req_cpu use_cpu req_mem use_mem pool <<< "$row"

    if [[ "$resource_label" == "cpu" ]]; then
      [[ -z "$waste_cpu" || "$waste_cpu" -le 0 ]] && continue
      suggested=$(suggest_cpu_m "$use_cpu" "$req_cpu")
      total_freed=$(( total_freed + req_cpu - suggested ))
      if   (( waste_cpu >= 2000 )); then cell_class="waste-heavy"
      elif (( waste_cpu >=  500 )); then cell_class="waste-med"
      else                               cell_class="waste-light"
      fi
      printf '<tr><td class="pool">%s</td><td>%s</td><td class="mono">%s</td><td class="mono">%s</td><td class="num">%s</td><td class="num">%s</td><td class="num %s">%s</td><td class="num">%s</td></tr>\n' \
        "$(html_escape "$pool")" \
        "$(html_escape "$ns")" \
        "$(html_escape "$pod")" \
        "$(html_escape "$container")" \
        "$(format_cpu_m "$req_cpu")" \
        "$(format_cpu_m "$use_cpu")" \
        "$cell_class" "$(format_cpu_m "$waste_cpu")" \
        "$(format_cpu_m "$suggested")"
    else
      [[ -z "$waste_mem" || "$waste_mem" -le 0 ]] && continue
      suggested=$(suggest_mem_mi "$use_mem" "$req_mem")
      total_freed=$(( total_freed + req_mem - suggested ))
      if   (( waste_mem >= 4096 )); then cell_class="waste-heavy"
      elif (( waste_mem >= 1024 )); then cell_class="waste-med"
      else                               cell_class="waste-light"
      fi
      printf '<tr><td class="pool">%s</td><td>%s</td><td class="mono">%s</td><td class="mono">%s</td><td class="num">%s</td><td class="num">%s</td><td class="num %s">%s</td><td class="num">%s</td></tr>\n' \
        "$(html_escape "$pool")" \
        "$(html_escape "$ns")" \
        "$(html_escape "$pod")" \
        "$(html_escape "$container")" \
        "$(format_mem_mi "$req_mem")" \
        "$(format_mem_mi "$use_mem")" \
        "$cell_class" "$(format_mem_mi "$waste_mem")" \
        "$(format_mem_mi "$suggested")"
    fi

    shown=$(( shown + 1 ))
    (( shown >= TOP_WASTERS )) && break
  done < <(printf "%s\n" "${WASTE_ROWS[@]}" | sort -t'|' -k${sort_field} -rn)

  echo '</tbody></table>'
  if [[ "$resource_label" == "cpu" ]]; then
    printf '<div class="section-note">Applying the suggested requests above would free approximately <strong>%s</strong> of reserved CPU.</div>\n' "$(format_cpu_m "$total_freed")"
  else
    printf '<div class="section-note">Applying the suggested requests above would free approximately <strong>%s</strong> of reserved memory.</div>\n' "$(format_mem_mi "$total_freed")"
  fi
  echo '</div>'
}

# ---------- main ----------

log "pod_resource_utilization_html.sh - owner: $SCRIPT_OWNER <$SCRIPT_OWNER_EMAIL>"
log "Collecting data for namespaces: ${NAMESPACES[*]}"

collect_target_agentpools

for namespace in "${NAMESPACES[@]}"; do
  collect_workload_replicas "$namespace"
done

collect_pod_pools
collect_pool_workload_totals
collect_node_allocatable_and_usage
collect_pending_pods
collect_waste_rows

compute_overall_status
log "Overall status: $OVERALL"

log "Writing HTML report to: $HTML"
{
  emit_html_header
  emit_agentpool_cpu_summary
  emit_agentpool_memory_summary
  emit_pool_pressure_alert
  emit_pending_pods
  emit_top_wasters 1 "Top ${TOP_WASTERS} CPU-Over-Provisioned Containers" cpu
  emit_top_wasters 2 "Top ${TOP_WASTERS} Memory-Over-Provisioned Containers" mem
  emit_html_footer
} > "$HTML"

send_email
