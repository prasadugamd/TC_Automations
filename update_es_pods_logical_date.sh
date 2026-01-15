#!/bin/bash

# Script to update logical date for all CR, FR, and RB pods
# This script loops through all matching pods and refreshes their logical date

set -e

echo "========================================="
echo "Starting Logical Date Update for Pods"
echo "Date: $(date)"
echo "========================================="

# Get all pods matching cr, fr, or rb
pods=$(oc get po | grep -E 'cr|fr|rb' | awk '{print $1}')

if [ -z "$pods" ]; then
    echo "No pods found matching pattern 'cr|fr|rb'"
    exit 1
fi

echo "Found pods:"
echo "$pods"
echo ""

# Loop through each pod
for pod in $pods; do
    echo "========================================="
    echo "Processing pod: $pod"
    echo "========================================="
    
    # Get the label (e.g., ES_CR31914)
    label=$(kubectl describe po "$pod" | grep Labels | awk '{print $2}' | awk -F "=" '{print $2}')
    
    if [ -z "$label" ]; then
        echo "WARNING: Could not retrieve label for pod $pod. Skipping..."
        continue
    fi
    
    echo "Label found: $label"
    
    # Get all container names in the pod
    containers=$(kubectl get po "$pod" -o jsonpath='{.spec.containers[*].name}')
    
    if [ -z "$containers" ]; then
        echo "WARNING: Could not retrieve container list for pod $pod. Skipping..."
        continue
    fi
    
    echo "Available containers: $containers"
    
    # Validate if label exists in the container list
    if ! echo "$containers" | grep -qw "$label"; then
        echo "WARNING: Label '$label' not found in container list for pod $pod. Skipping..."
        continue
    fi
    
    echo "✓ Validated: Label '$label' found in container list"
    echo "Using container: $label"
    
    # Check if .active-proccesses file exists in the container
    echo "Checking for .active-proccesses file in container $label..."
    kubectl exec -it -c "$label" "$pod" -- /bin/ksh -c "ls -la ~/.active-proccesses" 2>&1
    
    # Read the .active-proccesses file from the container
    value=$(kubectl exec -c "$label" "$pod" -- /bin/ksh -c "cat ~/.active-proccesses" 2>&1 | tr -d '\r\n')
    
    # Check if the file read was successful (doesn't contain error messages)
    if [ -z "$value" ] || echo "$value" | grep -iq "no such file"; then
        echo "WARNING: .active-proccesses file not found or empty in container $label for pod $pod. Skipping..."
        continue
    fi
    
    echo "Active processes value: $value"
    
    # Parse the value to extract part1 and part2
    part1=$(echo "$value" | awk -F'_' '{print $1}')
    part2=$(echo "$value" | awk -F'_' '{print $2}')
    
    echo "Part1: $part1"
    echo "Part2: $part2"
    
    if [ -z "$part1" ] || [ -z "$part2" ]; then
        echo "WARNING: Could not parse parts from .active-proccesses for pod $pod. Skipping..."
        continue
    fi
    
    # Connect to container shell and execute the command
    bin_dir="/home/xpiwrk1/abp_home/core/bin"
    script_path="$bin_dir/ADJ1_Send_Admin_Command_Sh"
    
    echo "Connecting to container $label shell..."
    
    # Validate if script exists
    echo "Validating script presence..."
    if ! kubectl exec -c "$label" "$pod" -- test -f "$script_path" 2>/dev/null; then
        echo "✗ ERROR: Script $script_path not found in container $label. Skipping..."
        continue
    fi
    
    echo "✓ Script found: $script_path"
    echo "Executing: ADJ1_Send_Admin_Command_Sh $pod $part1 $part2 REFRESH_LOGICAL_DATE_COMMAND"
    
    # Execute command in login shell to properly initialize environment
    kubectl exec -c "$label" "$pod" -- /bin/ksh -l -c "cd $bin_dir && ./ADJ1_Send_Admin_Command_Sh $pod $part1 $part2 REFRESH_LOGICAL_DATE_COMMAND"
    
    exit_code=$?
    
    if [ $exit_code -eq 0 ]; then
        echo "✓ Command executed successfully for pod $pod"
    else
        echo "✗ ERROR: Command failed for pod $pod"
    fi
    
    echo ""
    sleep 2  # Small delay between pods to avoid overwhelming the system
done

echo "========================================="
echo "Logical Date Update Completed"
echo "Date: $(date)"
echo "========================================="
