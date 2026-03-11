#!/bin/bash
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NOCOLOR='\033[0m'
if [ $# -lt 1 ]; then
  echo "Usage: $0 <namespace1> [<namespace2> ... <namespaceN>]"
  exit 1
fi
NAMESPACES=("$@")
declare -A POOL_ALLOC_CPU_M
declare -A POOL_USED_CPU_M
declare -A POOL_ALLOC_MEM_MI
declare -A POOL_USED_MEM_MI
declare -A POOL_LIMIT_CPU_M
declare -A POOL_LIMIT_MEM_MI
declare -A POOL_SEEN
declare -A TARGET_POOLS
declare -A NODE_POOL_CACHE

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
  if [[ -z "$value" ]]; then
    echo "N/A"
  elif (( value % 1000 == 0 )); then
    echo "$(( value / 1000 ))"
  else
    echo "${value}m"
  fi
}

format_mem_mi() {
  local value="$1"
  if [[ -z "$value" ]]; then
    echo "N/A"
  else
    echo "${value}Mi"
  fi
}

get_node_pool() {
  local node="$1"
  local pool_data
  local pool_label
  local alt_pool_label
  local pool

  if [[ -n "${NODE_POOL_CACHE["$node"]}" ]]; then
    echo "${NODE_POOL_CACHE["$node"]}"
    return
  fi

  pool_data=$(kubectl get node "$node" -o jsonpath='{.metadata.labels.agentpool}{"|"}{.metadata.labels.kubernetes\.azure\.com/agentpool}' 2>/dev/null)
  pool_label=${pool_data%%|*}
  alt_pool_label=${pool_data##*|}

  pool="$pool_label"
  if [[ -z "$pool" ]]; then
    pool="$alt_pool_label"
  fi
  if [[ -z "$pool" ]]; then
    pool="unassigned"
  fi

  NODE_POOL_CACHE["$node"]="$pool"
  echo "$pool"
}

collect_target_agentpools() {
  local namespace
  local node_list
  local node
  local pool

  for namespace in "${NAMESPACES[@]}"; do
    node_list=$(kubectl get pods -n "$namespace" -o jsonpath='{range .items[*]}{.spec.nodeName}{"\n"}{end}' 2>/dev/null | sort -u)

    while IFS= read -r node; do
      if [[ -z "$node" ]]; then
        continue
      fi

      pool=$(get_node_pool "$node")

      TARGET_POOLS["$pool"]=1
    done <<< "$node_list"
  done
}

collect_pool_total_limits() {
  local namespace
  local pod_limit_data
  local pod_record
  local node
  local limit_blob
  local pool
  local container_entry
  local limit_cpu
  local limit_mem
  local limit_cpu_m
  local limit_mem_mi

  for namespace in "${NAMESPACES[@]}"; do
    pod_limit_data=$(kubectl get pods -n "$namespace" -o jsonpath='{range .items[*]}{.spec.nodeName}{"|"}{range .spec.containers[*]}{@.resources.limits.cpu}{","}{@.resources.limits.memory}{";"}{end}{"\n"}{end}' 2>/dev/null)

    while IFS= read -r pod_record; do
      node=${pod_record%%|*}
      limit_blob=${pod_record#*|}

      if [[ -z "$node" || -z "$limit_blob" ]]; then
        continue
      fi

      pool=$(get_node_pool "$node")

      IFS=';' read -ra container_entries <<< "$limit_blob"
      for container_entry in "${container_entries[@]}"; do
        if [[ -z "$container_entry" ]]; then
          continue
        fi

        limit_cpu=${container_entry%%,*}
        limit_mem=${container_entry##*,}

        limit_cpu_m=$(cpu_to_m "$limit_cpu")
        limit_mem_mi=$(mem_to_mi "$limit_mem")

        if [[ -n "$limit_cpu_m" ]]; then
          POOL_LIMIT_CPU_M["$pool"]=$(( ${POOL_LIMIT_CPU_M["$pool"]:-0} + limit_cpu_m ))
        fi
        if [[ -n "$limit_mem_mi" ]]; then
          POOL_LIMIT_MEM_MI["$pool"]=$(( ${POOL_LIMIT_MEM_MI["$pool"]:-0} + limit_mem_mi ))
        fi
      done
    done <<< "$pod_limit_data"
  done
}

print_agentpool_summary() {
  local node_resource_data
  local node_usage_data
  local node
  local pool_label
  local alt_pool_label
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
  local AGENTPOOL_FORMAT
  local AGENTPOOL_SEPARATOR
  local alloc_cpu_total
  local limit_cpu_total
  local used_cpu_total
  local avail_cpu_total
  local alloc_mem_total
  local limit_mem_total
  local used_mem_total
  local avail_mem_total

  node_resource_data=$(kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"|"}{.metadata.labels.agentpool}{"|"}{.metadata.labels.kubernetes\.azure\.com/agentpool}{"|"}{.status.allocatable.cpu}{"|"}{.status.allocatable.memory}{"\n"}{end}' 2>/dev/null)
  node_usage_data=$(kubectl top nodes --no-headers 2>/dev/null)

  while IFS='|' read -r node pool_label alt_pool_label alloc_cpu alloc_mem; do
    if [[ -z "$node" ]]; then
      continue
    fi

    pool="$pool_label"
    if [[ -z "$pool" ]]; then
      pool="$alt_pool_label"
    fi
    if [[ -z "$pool" ]]; then
      pool="unassigned"
    fi

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

  AGENTPOOL_FORMAT="| %-20s | %-15s | %-15s | %-12s | %-15s | %-15s | %-18s | %-14s | %-16s |\n"
  AGENTPOOL_SEPARATOR="+----------------------+-----------------+-----------------+--------------+-----------------+-----------------+--------------------+----------------+------------------+"

  echo ""
  echo "AGENTPOOL RESOURCE SUMMARY"
  echo "$AGENTPOOL_SEPARATOR"
  printf "$AGENTPOOL_FORMAT" "AgentPool" "CPU Capacity" "Total Limit CPU" "CPU Used" "CPU Available" "Memory Capacity" "Total Limit Memory" "Memory Used" "Memory Available"
  echo "$AGENTPOOL_SEPARATOR"

  if [[ ${#TARGET_POOLS[@]} -eq 0 ]]; then
    printf "$AGENTPOOL_FORMAT" "N/A" "N/A" "N/A" "N/A" "N/A" "N/A" "N/A" "N/A" "N/A"
    echo "$AGENTPOOL_SEPARATOR"
    echo ""
    return
  fi

  while IFS= read -r pool; do
    if [[ -z "${TARGET_POOLS["$pool"]}" ]]; then
      continue
    fi

    alloc_cpu_total=${POOL_ALLOC_CPU_M["$pool"]:-0}
    limit_cpu_total=${POOL_LIMIT_CPU_M["$pool"]:-0}
    used_cpu_total=${POOL_USED_CPU_M["$pool"]:-0}
    avail_cpu_total=$(( alloc_cpu_total - used_cpu_total ))

    alloc_mem_total=${POOL_ALLOC_MEM_MI["$pool"]:-0}
    limit_mem_total=${POOL_LIMIT_MEM_MI["$pool"]:-0}
    used_mem_total=${POOL_USED_MEM_MI["$pool"]:-0}
    avail_mem_total=$(( alloc_mem_total - used_mem_total ))

    printf "$AGENTPOOL_FORMAT" "$pool" "$(format_cpu_m "$alloc_cpu_total")" "$(format_cpu_m "$limit_cpu_total")" "$(format_cpu_m "$used_cpu_total")" "$(format_cpu_m "$avail_cpu_total")" "$(format_mem_mi "$alloc_mem_total")" "$(format_mem_mi "$limit_mem_total")" "$(format_mem_mi "$used_mem_total")" "$(format_mem_mi "$avail_mem_total")"
  done < <(printf "%s\n" "${!POOL_SEEN[@]}" | sort)

  echo "$AGENTPOOL_SEPARATOR"
  echo ""
}

collect_target_agentpools
collect_pool_total_limits
print_agentpool_summary

TABLE_FORMAT="| %-20s | %-35s | %-25s | %-12s | %-15s | %-10s | %-15s | %-10s | %-12s | %-14s | %-16s |\n"
TABLE_SEPARATOR="+----------------------+-------------------------------------+---------------------------+--------------+-----------------+------------+-----------------+------------+--------------+----------------+------------------+"

echo "$TABLE_SEPARATOR"
printf "$TABLE_FORMAT" "Namespace" "Pod" "Container" "Request CPU" "Request Memory" "Limit CPU" "Limit Memory" "CPU Usage" "Memory Usage" "CPU Available" "Memory Available"
echo "$TABLE_SEPARATOR"

for namespace in "${NAMESPACES[@]}"; do
  pods=$(kubectl get pods -n $namespace -o jsonpath='{.items[*].metadata.name}')
for pod in $pods; do
  pod_usage=$(kubectl top pod $pod -n $namespace --containers)
  containers=$(kubectl get pod $pod -n $namespace -o jsonpath='{range .spec.containers[*]}{@.name} {@.resources.requests.cpu} {@.resources.requests.memory} {@.resources.limits.cpu} {@.resources.limits.memory}{"\n"}{end}')
  while IFS= read -r container; do
  container_name=$(echo $container | awk '{print $1}')
  request_cpu=$(echo $container | awk '{print $2}')
  request_memory=$(echo $container | awk '{print $3}')
  limit_cpu=$(echo $container | awk '{print $4}')
  limit_memory=$(echo $container | awk '{print $5}')
  cpu_usage=$(echo "$pod_usage" | grep -w "$container_name\s" | awk '{print $3}')
  mem_usage=$(echo "$pod_usage" | grep -w "$container_name\s" | awk '{print $4}')

  limit_cpu_m=$(cpu_to_m "$limit_cpu")
  cpu_usage_m=$(cpu_to_m "$cpu_usage")
  if [[ -n "$limit_cpu_m" && -n "$cpu_usage_m" ]]; then
    cpu_available_m=$(( limit_cpu_m - cpu_usage_m ))
    cpu_available=$(format_cpu_m "$cpu_available_m")
  else
    cpu_available="N/A"
  fi

  limit_mem_mi=$(mem_to_mi "$limit_memory")
  usage_mem_mi=$(mem_to_mi "$mem_usage")
  if [[ -n "$limit_mem_mi" && -n "$usage_mem_mi" ]]; then
    mem_available_mi=$(( limit_mem_mi - usage_mem_mi ))
    mem_available=$(format_mem_mi "$mem_available_mi")
  else
    mem_available="N/A"
  fi

  printf "$TABLE_FORMAT" "$namespace" "$pod" "$container_name" "$request_cpu" "$request_memory" "$limit_cpu" "$limit_memory" "$cpu_usage" "$mem_usage" "$cpu_available" "$mem_available"
 done <<< "$containers"
done
done

echo "$TABLE_SEPARATOR"
