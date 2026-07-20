#!/bin/bash
# ============================================================================
#  pod_multicloud_resource_utilization.sh
# ----------------------------------------------------------------------------
#  Owner       : Prasadu Gamini
#  Description : Multi-cloud Kubernetes POD / NodePool resource utilization
#                report (Reserved vs In-Use vs Schedulable vs Idle), pool
#                pressure alerts, pending pods, and top over-provisioned
#                containers with suggested request values.
#
#  Platforms   : AKS, EKS (+ Karpenter), GKE, OCI OKE, OpenShift (OCP),
#                and generic Kubernetes via POOL_LABEL_KEYS override.
#
#  Depends on  : kubectl (or oc), metrics-server (for 'top')
# ============================================================================
# Usage:
#   ./pod_multicloud_resource_utilization.sh <namespace1> [<namespace2> ...]
#   KUBE_CMD=oc ./pod_multicloud_resource_utilization.sh mynamespace
#   POOL_LABEL_KEYS=a1.at/node-pool ./pod_multicloud_resource_utilization.sh mynamespace
#   PRESSURE_THRESHOLD_PCT=25 TOP_WASTERS=20 ./pod_multicloud_resource_utilization.sh mynamespace
#
# Env vars:
#   KUBE_CMD                 kubectl | oc (auto-detected if unset)
#   POOL_LABEL_KEYS          comma-separated label keys (checked first, in order)
#   PRESSURE_THRESHOLD_PCT   default 20
#   TOP_WASTERS              default 15
# ============================================================================

if [ $# -lt 1 ]; then
  echo "Usage: $0 <namespace1> [<namespace2> ... <namespaceN>]" >&2
  echo "" >&2
  echo "Multi-cloud node-pool report for AKS / EKS / GKE / OKE / OCP." >&2
  echo "Optional: KUBE_CMD=oc  POOL_LABEL_KEYS=custom.label/key" >&2
  exit 1
fi

NAMESPACES=("$@")

# Prefer explicit KUBE_CMD; else kubectl; else oc (OpenShift)
if [[ -n "${KUBE_CMD:-}" ]]; then
  :
elif command -v kubectl >/dev/null 2>&1; then
  KUBE_CMD=kubectl
elif command -v oc >/dev/null 2>&1; then
  KUBE_CMD=oc
else
  echo "ERROR: neither kubectl nor oc found in PATH." >&2
  exit 1
fi

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
declare -A NODE_LABEL_CACHE
declare -A POD_WORKLOAD
declare -A POD_REPLICAS
declare -A POD_POOL
declare -a WASTE_ROWS
declare -a PENDING_ROWS

PRESSURE_THRESHOLD_PCT=${PRESSURE_THRESHOLD_PCT:-20}
TOP_WASTERS=${TOP_WASTERS:-15}

# Default pool label priority (first non-empty wins). Custom POOL_LABEL_KEYS are prepended.
DEFAULT_POOL_LABEL_KEYS=(
  "agentpool"
  "kubernetes.azure.com/agentpool"
  "eks.amazonaws.com/nodegroup"
  "karpenter.sh/nodepool"
  "karpenter.sh/provisioner-name"
  "cloud.google.com/gke-nodepool"
  "oci.oraclecloud.com/node-pool-id"
  "oci.oraclecloud.com/node.info.pool_id"
  "machine.openshift.io/cluster-api-machineset"
  "node.kubernetes.io/instance-type"
)

CLOUD="generic"
POOL_NOUN="NodePool"
DETECTED_POOL_KEY=""
METRICS_OK=1

cpu_to_m() {
  local value="$1"
  if [[ -z "$value" || "$value" == "<none>" ]]; then
    echo ""
    return
  fi
  if [[ "$value" =~ ^([0-9]+)m$ ]]; then
    echo "${BASH_REMATCH[1]}"
  elif [[ "$value" =~ ^([0-9]+\.[0-9]+)$ ]]; then
    # fractional cores e.g. 0.5 -> 500m
    echo "$(awk -v v="${BASH_REMATCH[1]}" 'BEGIN { printf "%d", v * 1000 }')"
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

  local number
  local unit
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

pct_of() {
  local part="$1"
  local total="$2"
  if [[ -z "$total" || "$total" -le 0 ]]; then
    echo "N/A"
    return
  fi
  echo "$(( part * 100 / total ))%"
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

# Load all labels for a node once (newline: key=value)
load_node_labels() {
  local node="$1"
  if [[ -n "${NODE_LABEL_CACHE["$node"]+x}" ]]; then
    echo "${NODE_LABEL_CACHE["$node"]}"
    return
  fi
  NODE_LABEL_CACHE["$node"]=$("$KUBE_CMD" get node "$node" \
    -o go-template='{{range $k,$v := .metadata.labels}}{{$k}}={{$v}}{{"\n"}}{{end}}' 2>/dev/null)
  echo "${NODE_LABEL_CACHE["$node"]}"
}

get_label_value() {
  local labels="$1"
  local key="$2"
  local line
  while IFS= read -r line; do
    if [[ "$line" == "${key}="* ]]; then
      echo "${line#*=}"
      return
    fi
  done <<< "$labels"
  echo ""
}

normalize_pool_name() {
  local pool="$1"
  # Shorten OCI node-pool OCIDs for readable tables
  if [[ "$pool" == ocid1.nodepool.* ]]; then
    echo "oke-${pool##*.}"
    return
  fi
  echo "$pool"
}

build_pool_label_keys() {
  POOL_LABEL_KEY_LIST=()
  if [[ -n "${POOL_LABEL_KEYS:-}" ]]; then
    local key
    IFS=',' read -ra _custom_keys <<< "$POOL_LABEL_KEYS"
    for key in "${_custom_keys[@]}"; do
      key="${key// /}"
      [[ -n "$key" ]] && POOL_LABEL_KEY_LIST+=("$key")
    done
  fi
  local def
  for def in "${DEFAULT_POOL_LABEL_KEYS[@]}"; do
    POOL_LABEL_KEY_LIST+=("$def")
  done
}

get_node_pool() {
  local node="$1"
  local labels
  local key
  local pool=""

  if [[ -n "${NODE_POOL_CACHE["$node"]}" ]]; then
    echo "${NODE_POOL_CACHE["$node"]}"
    return
  fi

  labels=$(load_node_labels "$node")

  for key in "${POOL_LABEL_KEY_LIST[@]}"; do
    pool=$(get_label_value "$labels" "$key")
    if [[ -n "$pool" ]]; then
      DETECTED_POOL_KEY="$key"
      break
    fi
  done

  if [[ -z "$pool" ]]; then
    pool="unassigned"
  else
    pool=$(normalize_pool_name "$pool")
  fi

  NODE_POOL_CACHE["$node"]="$pool"
  echo "$pool"
}

detect_cloud() {
  local sample_node
  local labels

  sample_node=$("$KUBE_CMD" get nodes -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
  if [[ -z "$sample_node" ]]; then
    CLOUD="generic"
    POOL_NOUN="NodePool"
    return
  fi

  labels=$(load_node_labels "$sample_node")

  if [[ -n "$(get_label_value "$labels" "kubernetes.azure.com/cluster")" ]] || \
     [[ -n "$(get_label_value "$labels" "agentpool")" ]]; then
    CLOUD="aks"
    POOL_NOUN="AgentPool"
  elif [[ -n "$(get_label_value "$labels" "eks.amazonaws.com/nodegroup")" ]] || \
       [[ -n "$(get_label_value "$labels" "karpenter.sh/nodepool")" ]] || \
       [[ -n "$(get_label_value "$labels" "karpenter.sh/provisioner-name")" ]]; then
    CLOUD="eks"
    POOL_NOUN="NodeGroup"
  elif [[ -n "$(get_label_value "$labels" "cloud.google.com/gke-nodepool")" ]]; then
    CLOUD="gke"
    POOL_NOUN="NodePool"
  elif [[ -n "$(get_label_value "$labels" "oci.oraclecloud.com/node-pool-id")" ]] || \
       [[ -n "$(get_label_value "$labels" "oci.oraclecloud.com/node.info.pool_id")" ]]; then
    CLOUD="oke"
    POOL_NOUN="NodePool"
  elif [[ -n "$(get_label_value "$labels" "node.openshift.io/os_id")" ]] || \
       [[ -n "$(get_label_value "$labels" "machine.openshift.io/cluster-api-machineset")" ]]; then
    CLOUD="ocp"
    POOL_NOUN="MachineSet"
  else
    CLOUD="generic"
    POOL_NOUN="NodePool"
  fi
}

check_prerequisites() {
  if ! "$KUBE_CMD" auth can-i get nodes >/dev/null 2>&1; then
    echo "WARN: cannot list nodes with $KUBE_CMD (check kubeconfig / RBAC)." >&2
  fi
  if ! "$KUBE_CMD" top nodes --no-headers >/dev/null 2>&1; then
    METRICS_OK=0
    echo "WARN: '$KUBE_CMD top nodes' failed — metrics-server may be missing." >&2
    echo "      In-Use / Idle / waste tables will show N/A or be incomplete." >&2
  fi
}

collect_target_pools() {
  local namespace
  local node_list
  local node
  local pool

  for namespace in "${NAMESPACES[@]}"; do
    node_list=$("$KUBE_CMD" get pods -n "$namespace" -o jsonpath='{range .items[*]}{.spec.nodeName}{"\n"}{end}' 2>/dev/null | sort -u)

    while IFS= read -r node; do
      if [[ -z "$node" ]]; then
        continue
      fi
      pool=$(get_node_pool "$node")
      TARGET_POOLS["$pool"]=1
    done <<< "$node_list"
  done
}

collect_pool_workload_totals() {
  local namespace
  local pod_data
  local pod_record
  local pod_name
  local node
  local resource_blob
  local pool
  local container_entry
  local req_cpu req_mem lim_cpu lim_mem
  local req_cpu_m req_mem_mi lim_cpu_m lim_mem_mi
  local pod_req_cpu_m pod_req_mem_mi pod_lim_cpu_m pod_lim_mem_mi
  local workload replicas
  local rest
  declare -A processed_workloads

  for namespace in "${NAMESPACES[@]}"; do
    pod_data=$("$KUBE_CMD" get pods -n "$namespace" -o jsonpath='{range .items[*]}{.metadata.name}{"|"}{.spec.nodeName}{"|"}{range .spec.containers[*]}{@.resources.requests.cpu}{","}{@.resources.requests.memory}{","}{@.resources.limits.cpu}{","}{@.resources.limits.memory}{";"}{end}{"\n"}{end}' 2>/dev/null)

    while IFS= read -r pod_record; do
      pod_name=${pod_record%%|*}
      rest=${pod_record#*|}
      node=${rest%%|*}
      resource_blob=${rest#*|}

      if [[ -z "$pod_name" || -z "$node" ]]; then
        continue
      fi

      workload="${POD_WORKLOAD["$namespace/$pod_name"]:-Pod/$pod_name}"

      if [[ -n "${processed_workloads["$namespace/$workload"]}" ]]; then
        continue
      fi
      processed_workloads["$namespace/$workload"]=1

      replicas="${POD_REPLICAS["$namespace/$pod_name"]:-1}"
      pool=$(get_node_pool "$node")

      pod_req_cpu_m=0
      pod_req_mem_mi=0
      pod_lim_cpu_m=0
      pod_lim_mem_mi=0

      IFS=';' read -ra container_entries <<< "$resource_blob"
      for container_entry in "${container_entries[@]}"; do
        if [[ -z "$container_entry" ]]; then
          continue
        fi

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

print_pool_summary() {
  local node_resource_data
  local node_usage_data
  local node
  local pool
  local alloc_cpu
  local alloc_mem
  local alloc_cpu_m
  local alloc_mem_mi
  local usage_fields
  local used_cpu
  local used_mem
  local used_cpu_m
  local used_mem_mi
  local alloc_cpu_total
  local req_cpu_total
  local limit_cpu_total
  local used_cpu_total
  local sched_free_cpu
  local live_free_cpu
  local alloc_mem_total
  local req_mem_total
  local limit_mem_total
  local used_mem_total
  local sched_free_mem
  local live_free_mem
  local CPU_FORMAT MEM_FORMAT CPU_SEPARATOR MEM_SEPARATOR
  local top_cmd_label="$KUBE_CMD top nodes"

  node_resource_data=$("$KUBE_CMD" get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"|"}{.status.allocatable.cpu}{"|"}{.status.allocatable.memory}{"\n"}{end}' 2>/dev/null)
  node_usage_data=$("$KUBE_CMD" top nodes --no-headers 2>/dev/null)

  while IFS='|' read -r node alloc_cpu alloc_mem; do
    if [[ -z "$node" ]]; then
      continue
    fi

    pool=$(get_node_pool "$node")
    POOL_SEEN["$pool"]=1

    alloc_cpu_m=$(cpu_to_m "$alloc_cpu")
    alloc_mem_mi=$(mem_to_mi "$alloc_mem")

    if [[ -n "$alloc_cpu_m" ]]; then
      POOL_ALLOC_CPU_M["$pool"]=$(( ${POOL_ALLOC_CPU_M["$pool"]:-0} + alloc_cpu_m ))
    fi
    if [[ -n "$alloc_mem_mi" ]]; then
      POOL_ALLOC_MEM_MI["$pool"]=$(( ${POOL_ALLOC_MEM_MI["$pool"]:-0} + alloc_mem_mi ))
    fi

    usage_fields=$(echo "$node_usage_data" | awk -v node_name="$node" '$1==node_name {print $2 "|" $4; exit}')
    used_cpu=${usage_fields%%|*}
    used_mem=${usage_fields##*|}

    used_cpu_m=$(cpu_to_m "$used_cpu")
    used_mem_mi=$(mem_to_mi "$used_mem")

    if [[ -n "$used_cpu_m" ]]; then
      POOL_USED_CPU_M["$pool"]=$(( ${POOL_USED_CPU_M["$pool"]:-0} + used_cpu_m ))
    fi
    if [[ -n "$used_mem_mi" ]]; then
      POOL_USED_MEM_MI["$pool"]=$(( ${POOL_USED_MEM_MI["$pool"]:-0} + used_mem_mi ))
    fi
  done <<< "$node_resource_data"

  CPU_FORMAT="| %-20s | %-14s | %-14s | %-16s | %-14s | %-16s | %-14s |\n"
  CPU_SEPARATOR="+----------------------+----------------+----------------+------------------+----------------+------------------+----------------+"

  MEM_FORMAT="| %-20s | %-16s | %-16s | %-18s | %-16s | %-18s | %-16s |\n"
  MEM_SEPARATOR="+----------------------+------------------+------------------+--------------------+------------------+--------------------+------------------+"

  echo ""
  echo "${POOL_NOUN} CPU SUMMARY [cloud=${CLOUD}] (Reserved = requests/limits x desired replicas; In-Use = ${top_cmd_label})"
  echo "$CPU_SEPARATOR"
  printf "$CPU_FORMAT" "$POOL_NOUN" "CPU Capacity" "CPU Reserved" "CPU Lim Reserved" "CPU In-Use" "CPU Schedulable" "CPU Idle"
  echo "$CPU_SEPARATOR"

  if [[ ${#TARGET_POOLS[@]} -eq 0 ]]; then
    printf "$CPU_FORMAT" "N/A" "N/A" "N/A" "N/A" "N/A" "N/A" "N/A"
    echo "$CPU_SEPARATOR"
    echo ""
    return
  fi

  while IFS= read -r pool; do
    if [[ -z "${TARGET_POOLS["$pool"]}" ]]; then
      continue
    fi

    alloc_cpu_total=${POOL_ALLOC_CPU_M["$pool"]:-0}
    req_cpu_total=${POOL_REQ_CPU_M["$pool"]:-0}
    limit_cpu_total=${POOL_LIMIT_CPU_M["$pool"]:-0}
    used_cpu_total=${POOL_USED_CPU_M["$pool"]:-0}
    sched_free_cpu=$(( alloc_cpu_total - req_cpu_total ))
    live_free_cpu=$(( alloc_cpu_total - used_cpu_total ))
    (( sched_free_cpu < 0 )) && sched_free_cpu=0
    (( live_free_cpu  < 0 )) && live_free_cpu=0

    printf "$CPU_FORMAT" "$pool" \
      "$(format_cpu_m "$alloc_cpu_total")" \
      "$(format_cpu_m "$req_cpu_total")" \
      "$(format_cpu_m "$limit_cpu_total")" \
      "$(format_cpu_m "$used_cpu_total")" \
      "$(format_cpu_m "$sched_free_cpu")" \
      "$(format_cpu_m "$live_free_cpu")"
  done < <(printf "%s\n" "${!POOL_SEEN[@]}" | sort)

  echo "$CPU_SEPARATOR"
  echo "  CPU Capacity     : total .status.allocatable.cpu across nodes in the pool."
  echo "  CPU Reserved     : sum of container CPU requests x desired replicas (what the SCHEDULER counts)."
  echo "  CPU Lim Reserved : sum of container CPU limits   x desired replicas (upper bound; may overcommit)."
  echo "  CPU In-Use       : real-time CPU usage from '${top_cmd_label}' (what's actually running)."
  echo "  CPU Schedulable  : CPU Capacity - CPU Reserved (headroom for scheduling new pods; if <=0 new pods go Pending)."
  echo "  CPU Idle         : CPU Capacity - CPU In-Use   (actual free CPU right now)."
  echo ""

  echo ""
  echo "${POOL_NOUN} MEMORY SUMMARY [cloud=${CLOUD}] (Reserved = requests/limits x desired replicas; In-Use = ${top_cmd_label})"
  echo "$MEM_SEPARATOR"
  printf "$MEM_FORMAT" "$POOL_NOUN" "Mem Capacity" "Mem Reserved" "Mem Lim Reserved" "Mem In-Use" "Mem Schedulable" "Mem Idle"
  echo "$MEM_SEPARATOR"

  while IFS= read -r pool; do
    if [[ -z "${TARGET_POOLS["$pool"]}" ]]; then
      continue
    fi

    alloc_mem_total=${POOL_ALLOC_MEM_MI["$pool"]:-0}
    req_mem_total=${POOL_REQ_MEM_MI["$pool"]:-0}
    limit_mem_total=${POOL_LIMIT_MEM_MI["$pool"]:-0}
    used_mem_total=${POOL_USED_MEM_MI["$pool"]:-0}
    sched_free_mem=$(( alloc_mem_total - req_mem_total ))
    live_free_mem=$(( alloc_mem_total - used_mem_total ))
    (( sched_free_mem < 0 )) && sched_free_mem=0
    (( live_free_mem  < 0 )) && live_free_mem=0

    printf "$MEM_FORMAT" "$pool" \
      "$(format_mem_mi "$alloc_mem_total")" \
      "$(format_mem_mi "$req_mem_total")" \
      "$(format_mem_mi "$limit_mem_total")" \
      "$(format_mem_mi "$used_mem_total")" \
      "$(format_mem_mi "$sched_free_mem")" \
      "$(format_mem_mi "$live_free_mem")"
  done < <(printf "%s\n" "${!POOL_SEEN[@]}" | sort)

  echo "$MEM_SEPARATOR"
  echo "  Mem Capacity     : total .status.allocatable.memory across nodes in the pool."
  echo "  Mem Reserved     : sum of container memory requests x desired replicas (what the SCHEDULER counts)."
  echo "  Mem Lim Reserved : sum of container memory limits   x desired replicas (upper bound; may overcommit)."
  echo "  Mem In-Use       : real-time memory usage from '${top_cmd_label}' (what's actually running)."
  echo "  Mem Schedulable  : Mem Capacity - Mem Reserved (headroom for scheduling new pods; if <=0 new pods go Pending)."
  echo "  Mem Idle         : Mem Capacity - Mem In-Use   (actual free memory right now)."
  echo ""
}

sum_container_resources() {
  local resource_blob="$1"
  local resource_kind="$2"
  local container_entry
  local req_cpu req_mem lim_cpu lim_mem
  local cpu_m mem_mi
  local total_cpu_m=0
  local total_mem_mi=0

  IFS=';' read -ra container_entries <<< "$resource_blob"
  for container_entry in "${container_entries[@]}"; do
    if [[ -z "$container_entry" ]]; then
      continue
    fi

    IFS=',' read -r req_cpu req_mem lim_cpu lim_mem <<< "$container_entry"

    case "$resource_kind" in
      req_cpu)
        cpu_m=$(cpu_to_m "$req_cpu")
        if [[ -n "$cpu_m" ]]; then
          total_cpu_m=$(( total_cpu_m + cpu_m ))
        fi
        ;;
      req_mem)
        mem_mi=$(mem_to_mi "$req_mem")
        if [[ -n "$mem_mi" ]]; then
          total_mem_mi=$(( total_mem_mi + mem_mi ))
        fi
        ;;
      lim_cpu)
        cpu_m=$(cpu_to_m "$lim_cpu")
        if [[ -n "$cpu_m" ]]; then
          total_cpu_m=$(( total_cpu_m + cpu_m ))
        fi
        ;;
      lim_mem)
        mem_mi=$(mem_to_mi "$lim_mem")
        if [[ -n "$mem_mi" ]]; then
          total_mem_mi=$(( total_mem_mi + mem_mi ))
        fi
        ;;
    esac
  done

  if [[ "$resource_kind" == req_cpu || "$resource_kind" == lim_cpu ]]; then
    echo "$total_cpu_m"
  else
    echo "$total_mem_mi"
  fi
}

collect_workload_replicas() {
  local namespace="$1"
  local name replicas owner_kind owner_name pod_name rs_name
  declare -A deploy_replicas
  declare -A sts_replicas
  declare -A ds_desired
  declare -A rs_to_deploy

  while IFS='|' read -r name replicas; do
    [[ -z "$name" ]] && continue
    deploy_replicas["$name"]="${replicas:-1}"
  done < <("$KUBE_CMD" get deployments -n "$namespace" -o jsonpath='{range .items[*]}{.metadata.name}{"|"}{.spec.replicas}{"\n"}{end}' 2>/dev/null)

  while IFS='|' read -r name replicas; do
    [[ -z "$name" ]] && continue
    sts_replicas["$name"]="${replicas:-1}"
  done < <("$KUBE_CMD" get statefulsets -n "$namespace" -o jsonpath='{range .items[*]}{.metadata.name}{"|"}{.spec.replicas}{"\n"}{end}' 2>/dev/null)

  while IFS='|' read -r name replicas; do
    [[ -z "$name" ]] && continue
    ds_desired["$name"]="${replicas:-1}"
  done < <("$KUBE_CMD" get daemonsets -n "$namespace" -o jsonpath='{range .items[*]}{.metadata.name}{"|"}{.status.desiredNumberScheduled}{"\n"}{end}' 2>/dev/null)

  while IFS='|' read -r rs_name owner_kind owner_name; do
    [[ -z "$rs_name" ]] && continue
    if [[ "$owner_kind" == "Deployment" ]]; then
      rs_to_deploy["$rs_name"]="$owner_name"
    fi
  done < <("$KUBE_CMD" get replicasets -n "$namespace" -o jsonpath='{range .items[*]}{.metadata.name}{"|"}{.metadata.ownerReferences[0].kind}{"|"}{.metadata.ownerReferences[0].name}{"\n"}{end}' 2>/dev/null)

  local workload
  local replica_count
  local parent_deploy
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
          replica_count=1
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
        replica_count=1
        ;;
      "")
        workload="Pod/$pod_name"
        replica_count=1
        ;;
      *)
        workload="${owner_kind}/${owner_name}"
        replica_count=1
        ;;
    esac
    POD_WORKLOAD["$namespace/$pod_name"]="$workload"
    POD_REPLICAS["$namespace/$pod_name"]="$replica_count"
  done < <("$KUBE_CMD" get pods -n "$namespace" -o jsonpath='{range .items[*]}{.metadata.name}{"|"}{.metadata.ownerReferences[0].kind}{"|"}{.metadata.ownerReferences[0].name}{"\n"}{end}' 2>/dev/null)
}

collect_pod_pools() {
  local namespace pod_name node
  for namespace in "${NAMESPACES[@]}"; do
    while IFS='|' read -r pod_name node; do
      [[ -z "$pod_name" || -z "$node" ]] && continue
      POD_POOL["$namespace/$pod_name"]=$(get_node_pool "$node")
    done < <("$KUBE_CMD" get pods -n "$namespace" -o jsonpath='{range .items[*]}{.metadata.name}{"|"}{.spec.nodeName}{"\n"}{end}' 2>/dev/null)
  done
}

collect_pending_pods() {
  local namespace pod_record pod_name phase resource_blob
  local container_entry req_cpu req_mem
  local req_cpu_m req_mem_mi
  local pod_req_cpu_m pod_req_mem_mi
  local reason rest

  for namespace in "${NAMESPACES[@]}"; do
    while IFS= read -r pod_record; do
      pod_name=${pod_record%%|*}
      rest=${pod_record#*|}
      phase=${rest%%|*}
      resource_blob=${rest#*|}

      [[ -z "$pod_name" ]] && continue
      [[ "$phase" != "Pending" ]] && continue

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

      reason=$("$KUBE_CMD" get event -n "$namespace" --field-selector involvedObject.name="$pod_name",reason=FailedScheduling -o jsonpath='{.items[-1:].message}' 2>/dev/null | head -c 120)
      [[ -z "$reason" ]] && reason="(no FailedScheduling event)"

      PENDING_ROWS+=("$namespace|$pod_name|$pod_req_cpu_m|$pod_req_mem_mi|$reason")
    done < <("$KUBE_CMD" get pods -n "$namespace" -o jsonpath='{range .items[*]}{.metadata.name}{"|"}{.status.phase}{"|"}{range .spec.containers[*]}{@.resources.requests.cpu}{","}{@.resources.requests.memory}{";"}{end}{"\n"}{end}' 2>/dev/null)
  done
}

print_pool_pressure_alert() {
  local pool alloc_cpu req_cpu used_cpu alloc_mem req_mem used_mem
  local sched_free_cpu sched_free_mem live_free_cpu live_free_mem
  local sched_cpu_pct sched_mem_pct live_cpu_pct live_mem_pct
  local sched_tight_cpu sched_tight_mem live_tight_cpu live_tight_mem
  local status
  local FORMAT SEPARATOR
  local flagged=0

  FORMAT="| %-20s | %-14s | %-12s | %-14s | %-12s | %-14s | %-14s | %-14s | %-14s | %-24s |\n"
  SEPARATOR="+----------------------+----------------+--------------+----------------+--------------+----------------+----------------+----------------+----------------+--------------------------+"

  echo ""
  echo "POOL PRESSURE ALERT (Schedulable = Capacity - Reserved; Idle = Capacity - In-Use; threshold ${PRESSURE_THRESHOLD_PCT}%)"
  echo "$SEPARATOR"
  printf "$FORMAT" "$POOL_NOUN" "CPU Schedulable" "% CPU Sched" "CPU Idle" "% CPU Idle" "Mem Schedulable" "% Mem Sched" "Mem Idle" "% Mem Idle" "Status"
  echo "$SEPARATOR"

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

    sched_cpu_pct=0
    sched_mem_pct=0
    live_cpu_pct=0
    live_mem_pct=0
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
    elif (( sched_tight_cpu || sched_tight_mem )); then
      status="RESERVED BUT IDLE - rightsize"
    else
      status="HOT - investigate bursts"
    fi

    flagged=1
    printf "$FORMAT" "$pool" \
      "$(format_cpu_m "$sched_free_cpu")" "${sched_cpu_pct}%" \
      "$(format_cpu_m "$live_free_cpu")"  "${live_cpu_pct}%" \
      "$(format_mem_mi "$sched_free_mem")" "${sched_mem_pct}%" \
      "$(format_mem_mi "$live_free_mem")"  "${live_mem_pct}%" \
      "$status"
  done < <(printf "%s\n" "${!POOL_SEEN[@]}" | sort)

  if [[ $flagged -eq 0 ]]; then
    printf "$FORMAT" "-" "-" "-" "-" "-" "-" "-" "-" "-" "No pools under pressure"
  fi

  echo "$SEPARATOR"
  echo "Status legend:"
  echo "  CRITICAL - add nodes           : Schedulable AND Idle both low on the same resource; new pods won't fit and nodes are hot -> add capacity."
  echo "  RESERVED BUT IDLE - rightsize  : Schedulable is low but nodes are Idle; requests over-book capacity -> trim requests (see TOP OVER-PROVISIONED tables)."
  echo "  HOT - investigate bursts       : Schedulable looks fine but Idle is low; workload is bursting -> check missing limits, GC pauses, noisy neighbours."
  echo ""
}

print_pending_pods_summary() {
  local row ns pod req_cpu_m req_mem_mi reason
  local FORMAT SEPARATOR

  FORMAT="| %-20s | %-40s | %-13s | %-15s | %-70s |\n"
  SEPARATOR="+----------------------+------------------------------------------+---------------+-----------------+------------------------------------------------------------------------+"

  echo ""
  echo "PENDING PODS (waiting to schedule)"
  echo "$SEPARATOR"
  printf "$FORMAT" "Namespace" "Pod" "Req CPU" "Req Memory" "Reason (last FailedScheduling event, truncated)"
  echo "$SEPARATOR"

  if [[ ${#PENDING_ROWS[@]} -eq 0 ]]; then
    printf "$FORMAT" "-" "no Pending pods found" "-" "-" "-"
    echo "$SEPARATOR"
    echo ""
    return
  fi

  for row in "${PENDING_ROWS[@]}"; do
    IFS='|' read -r ns pod req_cpu_m req_mem_mi reason <<< "$row"
    printf "$FORMAT" "$ns" "$pod" "$(format_cpu_m "$req_cpu_m")" "$(format_mem_mi "$req_mem_mi")" "$reason"
  done

  echo "$SEPARATOR"
  echo ""
}

print_top_wasters() {
  local sort_field="$1"
  local title="$2"
  local resource_label="$3"
  local row waste_cpu waste_mem ns pod container req_cpu use_cpu req_mem use_mem pool suggested
  local FORMAT SEPARATOR
  local shown=0
  local total_freed_cpu=0
  local total_freed_mem=0

  FORMAT="| %-15s | %-15s | %-33s | %-22s | %-12s | %-12s | %-12s | %-14s |\n"
  SEPARATOR="+-----------------+-----------------+-----------------------------------+------------------------+--------------+--------------+--------------+----------------+"

  echo ""
  echo "$title"
  echo "$SEPARATOR"
  printf "$FORMAT" "Pool" "Namespace" "Pod" "Container" "Request" "Actual" "Waste" "Suggested Req"
  echo "$SEPARATOR"

  if [[ ${#WASTE_ROWS[@]} -eq 0 ]]; then
    printf "$FORMAT" "-" "-" "no data" "-" "-" "-" "-" "-"
    echo "$SEPARATOR"
    echo ""
    return
  fi

  while IFS= read -r row; do
    IFS='|' read -r waste_cpu waste_mem ns pod container req_cpu use_cpu req_mem use_mem pool <<< "$row"

    if [[ "$resource_label" == "cpu" ]]; then
      [[ -z "$waste_cpu" || "$waste_cpu" -le 0 ]] && continue
      suggested=$(suggest_cpu_m "$use_cpu" "$req_cpu")
      total_freed_cpu=$(( total_freed_cpu + req_cpu - suggested ))
      printf "$FORMAT" "$pool" "$ns" "$pod" "$container" "$(format_cpu_m "$req_cpu")" "$(format_cpu_m "$use_cpu")" "$(format_cpu_m "$waste_cpu")" "$(format_cpu_m "$suggested")"
    else
      [[ -z "$waste_mem" || "$waste_mem" -le 0 ]] && continue
      suggested=$(suggest_mem_mi "$use_mem" "$req_mem")
      total_freed_mem=$(( total_freed_mem + req_mem - suggested ))
      printf "$FORMAT" "$pool" "$ns" "$pod" "$container" "$(format_mem_mi "$req_mem")" "$(format_mem_mi "$use_mem")" "$(format_mem_mi "$waste_mem")" "$(format_mem_mi "$suggested")"
    fi

    shown=$(( shown + 1 ))
    (( shown >= TOP_WASTERS )) && break
  done < <(printf "%s\n" "${WASTE_ROWS[@]}" | sort -t'|' -k${sort_field} -rn)

  echo "$SEPARATOR"
  if [[ "$resource_label" == "cpu" ]]; then
    echo "Applying the suggested requests above would free approximately $(format_cpu_m "$total_freed_cpu") of reserved CPU."
  else
    echo "Applying the suggested requests above would free approximately $(format_mem_mi "$total_freed_mem") of reserved memory."
  fi
  echo ""
}

# ---- main ----
build_pool_label_keys
detect_cloud
check_prerequisites

echo "Multi-cloud POD resource utilization"
echo "  CLI          : $KUBE_CMD"
echo "  Detected     : $CLOUD ($POOL_NOUN)"
echo "  Namespaces   : ${NAMESPACES[*]}"
[[ -n "${POOL_LABEL_KEYS:-}" ]] && echo "  Pool labels  : $POOL_LABEL_KEYS (override)"
echo ""

collect_target_pools

for namespace in "${NAMESPACES[@]}"; do
  collect_workload_replicas "$namespace"
done

collect_pod_pools
collect_pool_workload_totals
print_pool_summary

for namespace in "${NAMESPACES[@]}"; do
  pods=$("$KUBE_CMD" get pods -n "$namespace" --field-selector=status.phase=Running -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)
  for pod in $pods; do
    pod_usage=$("$KUBE_CMD" top pod "$pod" -n "$namespace" --containers 2>/dev/null)
    containers=$("$KUBE_CMD" get pod "$pod" -n "$namespace" -o jsonpath='{range .spec.containers[*]}{@.name} {@.resources.requests.cpu} {@.resources.requests.memory} {@.resources.limits.cpu} {@.resources.limits.memory}{"\n"}{end}' 2>/dev/null)
    replicas="${POD_REPLICAS["$namespace/$pod"]:-1}"
    while IFS= read -r container; do
      [[ -z "$container" ]] && continue
      container_name=$(echo "$container" | awk '{print $1}')
      request_cpu=$(echo "$container" | awk '{print $2}')
      request_memory=$(echo "$container" | awk '{print $3}')
      limit_cpu=$(echo "$container" | awk '{print $4}')
      limit_memory=$(echo "$container" | awk '{print $5}')
      # Match container name as whole field (column 2 of kubectl top --containers)
      cpu_usage=$(echo "$pod_usage" | awk -v c="$container_name" '$2==c {print $3; exit}')
      mem_usage=$(echo "$pod_usage" | awk -v c="$container_name" '$2==c {print $4; exit}')

      limit_cpu_m=$(cpu_to_m "$limit_cpu")
      cpu_usage_m=$(cpu_to_m "$cpu_usage")
      limit_mem_mi=$(mem_to_mi "$limit_memory")
      usage_mem_mi=$(mem_to_mi "$mem_usage")
      req_cpu_m=$(cpu_to_m "$request_cpu")
      req_mem_mi=$(mem_to_mi "$request_memory")

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

collect_pending_pods
print_pool_pressure_alert
print_pending_pods_summary
print_top_wasters 1 "TOP ${TOP_WASTERS} CPU-OVER-PROVISIONED CONTAINERS (biggest CPU waste = request - actual usage)" cpu
print_top_wasters 2 "TOP ${TOP_WASTERS} MEMORY-OVER-PROVISIONED CONTAINERS (biggest Memory waste = request - actual usage)" mem

echo "Notes:"
echo "  - Cloud auto-detect: aks | eks | gke | oke | ocp | generic  (header uses $POOL_NOUN)."
echo "  - Override pool grouping: POOL_LABEL_KEYS=my.org/node-pool"
echo "  - Label priority: custom keys, then AKS, EKS, Karpenter, GKE, OKE, OCP MachineSet."
echo "  - 'Suggested Req' = usage x 1.5 (CPU) / 1.3 (Memory), rounded up, capped at current request."
echo "  - Suggestions are based on a single '${KUBE_CMD} top' sample. For bursty workloads use p95 (Prometheus / cloud monitor / krr)."
echo "  - Tune: PRESSURE_THRESHOLD_PCT (default 20), TOP_WASTERS (default 15), KUBE_CMD=kubectl|oc."
echo ""
