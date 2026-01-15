# ES Pods Logical Date Update Script

## Author
**Prasadu Gamini**

## Objective
Automate the process of updating the logical date for Enterprise Services (ES) pods in a Kubernetes/OpenShift environment, specifically targeting CR (Change Request), FR (Functional Requirement), and RB (Rollback) pods.

## Description
This bash script automates the logical date refresh operation for all ES pods matching specific patterns (CR, FR, RB) in a Kubernetes/OpenShift cluster. It eliminates the manual effort required to update logical dates across multiple pods by systematically identifying pods, extracting their configuration, and executing the refresh command on each container.

The script is designed to work with Amdocs Billing Platform (ABP) environments where pods contain multiple containers and require periodic logical date updates for proper system operation.

## Functionality

### Core Features:
1. **Pod Discovery**: Automatically identifies all pods matching the pattern 'cr', 'fr', or 'rb' using OpenShift CLI commands
2. **Label Extraction**: Retrieves pod labels to identify the correct container for command execution
3. **Container Validation**: Verifies that the target container exists within each pod
4. **Active Processes Detection**: Reads the `.active-proccesses` file from each container to extract required parameters
5. **Command Execution**: Executes the `ADJ1_Send_Admin_Command_Sh` script with the `REFRESH_LOGICAL_DATE_COMMAND` parameter
6. **Error Handling**: Implements comprehensive validation and error checking with informative messages

### Workflow:
1. Lists all pods matching the CR/FR/RB pattern
2. For each pod:
   - Extracts the pod label (e.g., ES_CR31914)
   - Retrieves all container names in the pod
   - Validates that the label exists as a container name
   - Checks for the existence of `.active-proccesses` file
   - Parses the file to extract part1 and part2 parameters
   - Validates the existence of the admin command script
   - Executes the refresh logical date command in a login shell
   - Reports success or failure status
3. Provides detailed logging for monitoring and troubleshooting

### Requirements:
- OpenShift CLI (`oc`) or Kubernetes CLI (`kubectl`)
- Access to the target Kubernetes/OpenShift cluster
- Appropriate permissions to execute commands in pod containers
- Pods must contain the ABP core binary directory structure

### Usage:
```bash
./update_es_pods_logical_date.sh
```

### Output:
The script provides real-time progress updates including:
- Start and end timestamps
- List of discovered pods
- Processing status for each pod
- Validation results
- Command execution results
- Error messages and warnings for any issues encountered
