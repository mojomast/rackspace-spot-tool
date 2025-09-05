# Remote VS Code Environment on Rackspace Spot

## Overview

This project provides an automated solution to set up a remote Visual Studio Code (code-server) environment on Rackspace Spot infrastructure. It leverages Terraform for provisioning unmanaged Kubernetes clusters on Spot instances and Helm for deploying code-server, enabling cost-effective, scalable development environments.

The environment allows you to run VS Code in your browser on spot-priced cloud resources, perfect for development, testing, or lightweight workloads.

Key features include:
- **Cost-effective hosting**: Uses Rackspace Spot instances with configurable bidding. API base URL is now centralized via `SPOT_API_BASE` environment variable.
- **Automated provisioning**: Scripts handle infrastructure setup, deployment, and management.
- **Flexible deployment**: Deploy code-server to existing infrastructure via separate deploy script.
- **Persistent storage**: Configurable PVC for data retention.
- **Load balancing**: Exposes code-server via LoadBalancer or ClusterIP services.
- **Management scripts**: Provision, pause, and resume the environment as needed.

## Infrastructure Comparison: Gen-1 vs Gen-2

Rackspace Spot offers two generations of infrastructure optimized for different workloads. Choose Gen-2 for modern, high-performance applications requiring NVMe storage and high-speed networking, or Gen-1 for cost-effective general-purpose computing.

| Feature             | Gen-1                          | Gen-2                                  |
|---------------------|-------------------------------|---------------------------------------|
| **Cost Optimizations** | Standard Spot pricing with up to 50% savings | Advanced dynamic bidding, up to 70% cheaper |
| **Hardware Features**| SATA SSD storage             | NVMe SSD storage for faster I/O       |
| **Network Speeds**    | 1GbE                          | 40GbE for high-throughput workloads   |
| **GPU Support**      | Basic GPU servers (e.g., 1x NVIDIA T4) | Enhanced GPU servers (e.g., multiple NVIDIA A100, up to 8 GPUs) |
| **Use Cases**        | General development, CI/CD   | Machine learning, data analytics, AI training |

## Getting Started

This section guides you through the initial setup, including selecting options from interactive menus, running the provided scripts, and accessing code-server.

### Interactive Options Selection

The scripts use numbered selection menus for key configuration options to simplify setup. Region and server class options are now dynamically populated from the Rackspace Spot API:

- **REGION** (in [`provision.sh`](provision.sh)):
  - Dynamically fetched from `GET /regions` API endpoint
  - Options vary based on your account and available regions
  - Script validates region accessibility before proceeding

- **SERVER_CLASS** (in [`provision.sh`](provision.sh) and [`deploy-code-server.sh`](deploy-code-server.sh)):
  - Dynamically fetched from `GET /serverclasses?region=<selected-region>` API endpoint
  - Available options depend on your selected region
  - Each server class includes validated fields: vCPU, memoryGB, price/hour, gpu_info (if present)
  - Supports GPU-enabled instances based on region capabilities
  - **Cost-effectiveness ranking**: Server classes are ranked by cost-effectiveness score
    - Formula: `score = price_per_hour / (vcpu_weight * vCPUs + mem_weight * memory_gb + gpu_weight * gpu_count)`
    - Default weights: `VCPU_WEIGHT=1.0`, `MEM_WEIGHT=0.5`, `GPU_WEIGHT=4.0`
    - Adjustable via environment variables or `--metric` option
  - `--metric` option controls ranking strategy:
    - `cpu-only`: Only considers CPU cost
    - `cpu+mem`: Ignores GPU costs
    - `cpu+mem+gpu` (default): Full cost-effectiveness including GPUs
    - `custom`: Use custom weights from environment variables

- **SERVICE_TYPE** (in [`deploy-code-server.sh`](deploy-code-server.sh)):
  - 1. LoadBalancer - External access via public IP (e.g., for internet access)
  - 2. ClusterIP - Internal access within cluster only (secure for private use)

- **TIMEZONE** (in [`deploy-code-server.sh`](deploy-code-server.sh)):
  - 1. UTC - Coordinated Universal Time (recommended for consistency)
  - 2. America/New_York - Eastern Time
  - 3. Europe/London - Greenwich Mean Time
  - 4. Asia/Tokyo - Japan Standard Time
  - 5. America/Los_Angeles - Pacific Time
  - 6. Europe/Paris - Central European Time

- **KUBECONFIG_PATH** (in [`deploy-code-server.sh`](deploy-code-server.sh)):
  - 1. ~/.kube/config - Default user kubeconfig
  - 2. /etc/kubernetes/admin.conf - Admin config (e.g., in-cluster)
  - 3. Custom path - Enter your own path
  - 4. Cancel - Exit script

To use the menus:
1. Run the script (e.g., `./provision.sh`).
2. Navigate menus using numbers and press Enter to select.
3. For custom options like KUBECONFIG_PATH, choose the custom option and enter details when prompted.
4. Region and server class options are fetched live from the Rackspace Spot API, ensuring current availability.

### Running the Scripts

Execute the following scripts for different operations:

1. **Provisioning Infrastructure** ([`provision.sh`](provision.sh)):
    - Usage: `./provision.sh [--dry-run] [--debug] [--metric cpu-only|cpu+mem|custom]`
    - Flags/Options: `--dry-run` for validation, `--debug` for verbose error output, `--metric` for cost-effectiveness ranking strategy
    - Environment Variables: Adjust weights with `VCPU_WEIGHT`, `MEM_WEIGHT`, `GPU_WEIGHT`
    - Typical Command: `./provision.sh --metric cpu+mem+gpu` (uses full cost-effectiveness ranking)
    - Provisions infrastructure, sets up kubeconfig, and deploys code-server

2. **Deploying Code-Server** ([`deploy-code-server.sh`](deploy-code-server.sh)):
   - Usage: `./deploy-code-server.sh [--debug]`
   - Flags/Options: `--debug` for verbose error output, Interactive prompts for NAMESPACE, CODE_SERVER_PASSWORD, STORAGE_SIZE, TIMEZONE, SERVICE_TYPE
   - Typical Command: `./deploy-code-server.sh` (assumes infrastructure exists)
   - Deploys code-server to existing Kubernetes cluster using dynamic API endpoints.

3. **Pausing the Environment** ([`pause.sh`](pause.sh)):
   - Usage: `./pause.sh [--debug]`
   - Flags/Options: `--debug` for verbose error output, prompts for credentials and paths
   - Typical Command: `./pause.sh` (scales to zero nodes for cost savings)

5. **Sanity Checks** ([`scripts/sanity-check.sh`](scripts/sanity-check.sh)):
    - Usage: `./scripts/sanity-check.sh [--dry-run] [--debug]`
    - Validates Rackspace Spot API connectivity and organization access
    - Checks for available regions (expects >= 1) and cloudspaces
    - Verifies Kubernetes cluster access if kubectl is available
    - Returns non-zero exit code on failures with human-friendly error messages
    - Typical Command: `./scripts/sanity-check.sh` (runs validation checks)

4. **Resuming the Environment** ([`resume.sh`](resume.sh)):
    - Usage: `./resume.sh [--debug]`
    - Flags/Options: `--debug` for verbose error output, prompts for credentials and node count
    - Typical Command: `./resume.sh` (restores nodes and redeploys code-server)

Ensure scripts are executable: `chmod +x provision.sh deploy-code-server.sh pause.sh resume.sh scripts/sanity-check.sh`.

### Terraform Configuration
The main.tf file now uses the variable `spot_token` for authentication.

To run Terraform commands:

1. **Initialize Terraform** (install providers):
   ```bash
   terraform init
   ```

2. **Plan changes** (preview what will be created):
   ```bash
   terraform plan
   ```

3. **Apply changes** (provision infrastructure):
   ```bash
   terraform apply
   ```

To provide the token via environment variable:
```bash
export TF_VAR_spot_token="$SPOT_API_TOKEN"
terraform plan
```

Or pass directly:
```bash
terraform plan -var="spot_token=$SPOT_API_TOKEN"
```

Copy `terraform.tfvars.example` to `terraform.tfvars` and customize the values for your deployment:
```bash
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars with your values
terraform apply -var-file=terraform.tfvars
```

To destroy resources:
```bash
terraform destroy
```

### Accessing Code-Server

Once deployed, access code-server via browser or VS Code:

#### Browser Access
- **LoadBalancer Service**: Access via external public IP provided by the script.
  - Example: `http://123.45.67.89` (default port 80)
  - Check status: `kubectl get svc -n code-server`
- **ClusterIP Service**: Use port-forwarding for local access.
  - Command: `kubectl port-forward -n code-server svc/code-server 8080:80`
  - Browse: `http://localhost:8080`

#### VS Code Access
- Use Remote-SSH extension or connect to the container.
- For LoadBalancer: Connect to `vscode@<EXTERNAL_IP>@80`
- For ClusterIP: First set up port-forward, then connect to `vscode@localhost:8080`
- The scripts provide SSH config snippets for easy setup.

## Prerequisites

Before using this project, ensure you have the following installed and configured:

### Required Tools
- **Terraform**: Version >= 1.0.0 (download from [terraform.io](https://www.terraform.io/downloads)).
- **kubectl**: For managing Kubernetes resources (install via [kubernetes.io/docs](https://kubernetes.io/docs/tasks/tools/)).
- **Helm**: Version 3.x for deploying charts (install via [helm.sh/docs](https://helm.sh/docs/intro/install/)).
- **jq**: For JSON processing in scripts (install via package manager).
- **Bash/shell**: Compatible with Unix-like systems (Linux/macOS/Windows with WSL).

### Rackspace Account Setup
1. Create an account on [Rackspace.com](https://www.rackspace.com).
2. Obtain your **API Token** from the Rackspace Spot Control Panel or use OAuth client credentials.
3. Ensure your account has permissions for Spot instances and Kubernetes resources.

### Authentication Setup
The scripts use token-based authentication with Rackspace Spot API.

**Option 1: Direct API Token (Recommended)**
- Set environment variable: `export SPOT_API_TOKEN="your-token-here"`
- Obtain token from Rackspace Spot Control Panel.

**Option 2: OAuth Client Credentials**
- Set: `export SPOT_CLIENT_ID="your-client-id"`
- Set: `export SPOT_CLIENT_SECRET="your-client-secret"`
- The scripts will automatically obtain and cache tokens.

Tokens are cached in `${XDG_RUNTIME_DIR:-/tmp}/spot_token.json` to avoid repeated requests.

### Cost-Effectiveness Weights
You can customize how server classes are ranked by adjusting the cost-effectiveness weights:

- `VCPU_WEIGHT`: Weight for CPU cores (default: 1.0)
- `MEM_WEIGHT`: Weight for memory in GB (default: 0.5)
- `GPU_WEIGHT`: Weight for GPU count (default: 4.0)

Example:
```bash
export VCPU_WEIGHT="1.0"
export MEM_WEIGHT="1.0"    # Increase memory importance
export GPU_WEIGHT="8.0"    # Increase GPU importance further
```

## GPU Support

The tool now provides comprehensive GPU/accelerator server class support:

### Features
- **Automatic GPU Detection**: Scripts detect GPU-enabled server classes from Spot API responses
- **Node Scheduling**: GPU workloads are automatically scheduled to GPU-enabled nodes using labels and taints
- **Device Plugin**: NVIDIA GPU device plugin is deployed when GPU server classes are selected
- **Resource Management**: GPU resources are properly allocated to workloads

### Required Cluster Addons
When deploying to GPU-enabled node pools, ensure the following cluster addons are available:

1. **NVIDIA GPU Operator** (recommended):
   ```bash
   # Install NVIDIA GPU Operator via Helm
   helm repo add nvidia https://helm.ngc.nvidia.com/nvidia
   helm repo update
   helm install gpu-operator nvidia/gpu-operator
   ```

2. **NVIDIA Device Plugin** (alternative):
   ```bash
   kubectl create -f https://raw.githubusercontent.com/NVIDIA/k8s-device-plugin/v0.14.0/nvidia-device-plugin.yml
   ```

### GPU Server Classes
The tool supports GPU-enabled server classes that include:
- `gpu1-xlarge`: Single GPU configurations
- `gpu1-2xlarge`: Dual GPU configurations
- Additional GPU classes as available in your region

### Configuration
GPU settings are automatically configured based on the selected server class:
- Node selectors: `nvidia.com/gpu: present`
- Tolerations: `nvidia.com/gpu=present:NoSchedule`
- Resource limits: Based on detected GPU count
- Device plugin: Enabled automatically for GPU workloads

### Organization Namespace
- Set environment variable: `export SPOT_ORG_NAMESPACE="your-organization-namespace"`
- This is required for scoping API calls to your organization's resources.
- Obtain your organization namespace from the Rackspace Spot Control Panel or API documentation.

### Network Requirements
- Ensure outbound connectivity for Terraform to reach Rackspace APIs.
- Port 80/8080 should be open for accessing code-server.

## Quick Start

1. Clone or download the project files to your local machine.
2. Make scripts executable: `chmod +x provision.sh deploy-code-server.sh pause.sh resume.sh`.
3. **Option A: Full provisioning** - Run the provisioning script with the --dry-run flag for validation: `./provision.sh --dry-run`.
   - This will validate the orchestration without making actual API calls or Terraform changes.
   - If successful, run without --dry-run to execute the full provisioning: `./provision.sh`.
4. **Option B: Deploy to existing infrastructure** - If infrastructure is already provisioned via Terraform and kubeconfig exists:
   - Run: `./deploy-code-server.sh --dry-run` to validate the deployment process.
   - This will simulate the Helm deployment without actually executing it.
   - If successful, run without --dry-run to deploy: `./deploy-code-server.sh`.

## Sanity Checks (Validation Checklist)

After deployment, verify the environment with these commands. Run them post-provision to ensure everything is set up correctly.

### Verifying Cluster and Resources

1. **Check Cluster Nodes** (`kubectl get nodes`):
   - Verifies Kubernetes nodes are running and ready.
   - Example Output:
     ```
     NAME               STATUS   ROLES    AGE   VERSION
     node-01   Ready    <none>   10m   v1.28.0
     node-02   Ready    <none>   10m   v1.28.0
     ```
   - Troubleshooting: If nodes are NotReady, check network connectivity or Spot instance availability. May indicate issues with Rackspace credentials or bidding.

2. **Check Persistent Volume Claims** (`kubectl get pvc -n code-server`):
   - Ensures storage is bound for code-server.
   - Example Output:
     ```
     NAME             STATUS   VOLUME                                     CAPACITY   ACCESS MODES   STORAGECLASS          AGE
     code-server-pvc  Bound    pvc-12345678-1234-1234-1234-123456789abc   10Gi       RWO            rackspace-block-v6    5m
     ```
   - Troubleshooting: If STATUS is "Pending", storage class may not be available. Check `kubectl get storageclass` for available classes. Ensure PVC size is within account limits.

3. **Check Services** (`kubectl get svc -n code-server`):
   - Verifies code-server service is exposed correctly.
   - Example Output for LoadBalancer:
     ```
     NAME          TYPE           CLUSTER-IP     EXTERNAL-IP     PORT(S)        AGE
     code-server   LoadBalancer   10.100.0.1    123.45.67.89    80:31234/TCP   5m
     ```
   - Example Output for ClusterIP:
     ```
     NAME          TYPE        CLUSTER-IP     EXTERNAL-IP   PORT(S)   AGE
     code-server   ClusterIP   10.100.0.1     <none>        80/TCP    5m
     ```
   - Troubleshooting: For LoadBalancer, if EXTERNAL-IP is "<pending>", wait longer as provisioning can take 5-10 minutes. For ClusterIP, use port-forwarding. Check `kubectl describe svc code-server -n code-server` for events if stuck.

Run these commands sequentially; all should show READY/Ready/Bound statuses for a successful setup. Address any failures before proceeding, as they can prevent code-server access.

## Detailed Usage

### Provisioning the Environment (provision.sh)

This script provisions the infrastructure using Terraform, sets up the Kubernetes cluster, and deploys code-server via Helm.

**Steps:**
1. Open a terminal in the project directory.
2. Run the script:
   ```bash
   ./provision.sh
   ```
3. Respond to interactive prompts with your Rackspace credentials and preferences.
4. The script will:
   - Initialize and apply Terraform configuration for Spot infrastructure.
   - Retrieve and configure kubeconfig for cluster access.
   - Add Helm repositories and deploy code-server.
   - Wait for pods to become ready.
   - Provide the access URL for code-server.

**Output Example:**
```
2023-09-04 22:03:00 - code-server is ready! Access it at: http://123.45.67.89
```

**Notes:**
- Provisioning may take 10-15 minutes depending on resource availability.
- If external IP is not immediately available, use `kubectl port-forward` as suggested by the script.

### Deploying Code-Server (deploy-code-server.sh)

This script deploys code-server to an existing Kubernetes cluster without provisioning infrastructure. Assumes Terraform has created the cluster, PVC, and kubeconfig.

**Steps:**
1. Ensure KUBECONFIG is set to point to your existing cluster.
2. Run the script:
   ```bash
   ./deploy-code-server.sh
   ```
3. Respond to interactive prompts for customization:
   - KUBECONFIG_PATH: Path to existing kubeconfig
   - NAMESPACE: Kubernetes namespace for deployment
   - CODE_SERVER_PASSWORD: Password for code-server access
   - STORAGE_SIZE: PVC size (e.g., 10Gi)
   - TIMEZONE: Timezone for the container
   - SERVICE_TYPE: LoadBalancer or ClusterIP
4. The script will:
   - Validate kubeconfig and cluster connectivity.
   - Create namespace if it doesn't exist.
   - Add/update PascalIske Helm repo.
   - Generate values.yaml from template.
   - Deploy code-server via Helm.
   - Wait for pods to become ready.
   - For LoadBalancer: Wait for external IP and provide access URL.
   - For ClusterIP: Provide port-forward command.

**Output Example:**
```
2023-09-04 22:05:00 - Using KUBECONFIG: /path/to/kubeconfig
2023-09-04 22:05:01 - Successfully connected to Kubernetes cluster
2023-09-04 22:05:02 - Namespace code-server already exists
2023-09-04 22:05:03 - Helm repo updated successfully
2023-09-04 22:05:04 - values.yaml generated successfully
2023-09-04 22:05:05 - Helm command executed successfully
2023-09-04 22:05:06 - Pods are ready
2023-09-04 22:05:07 - SUCCESS: code-server is ready! Access it at: http://123.45.67.89
```

**Notes:**
- Designed for use after infrastructure is provisioned externally.
- Supports both LoadBalancer and ClusterIP service types.
- Idempotent: Can be re-run safely with the same inputs.
- Temporary deploy-values.yaml is created; original values.yaml remains unchanged.
- Deployment typically completes in 2-5 minutes.

### Pausing the Environment (pause.sh)

Safely scale down the environment to zero cost by draining pods and reducing the node pool to zero.

**Steps:**
1. Ensure kubeconfig is set (or specify path when prompted).
2. Run the script:
   ```bash
   ./pause.sh
   ```
3. Enter Rackspace credentials and confirm paths.
4. The script will:
   - Drain code-server pods from nodes.
   - Update Terraform variables to set node count to 0.
   - Apply Terraform changes to scale down.

**Output:** Logs all actions; check `pause.log` for details.

**Notes:**
- Data persists via PVC; no data loss occurs.
- Resume via the resume script when ready.

### Resuming the Environment (resume.sh)

Restore the environment by scaling nodes back up and redeploying code-server.

**Steps:**
1. Run the script:
   ```bash
   ./resume.sh
   ```
2. Enter credentials and desired node count.
3. The script will:
   - Apply Terraform to restore node count.
   - Wait for nodes to join and PVC to bind.
   - Upgrade/reinstall Helm release for code-server.
   - Provide updated access URL.

**Output Example:**
```
2023-09-04 22:03:00 - Resume script completed successfully
External IP: 123.45.67.89
Access code-server at http://123.45.67.89
```

## Default Values for Prompts

The scripts use the following defaults; press Enter to accept them:

| Prompt                | Default Value                  | Notes                                      |
|-----------------------|--------------------------------|--------------------------------------------|
| **Provisioning Script (provision.sh)** |                                |                                            |
| REGION                | us-east-iad-1 (Ashburn, VA)    | Rackspace Spot region; dynamically fetched |
| BID_PRICE            | 0.03 USD/hour                 | Spot bid; must be >0, <=1.0              |
| NODE_COUNT           | 1                              | Desired nodes; 1-10                       |
| KUBECONFIG_PATH      | ~/.kube/config (expanded)     | Path to Kubernetes config               |
| PVC_SIZE             | 10Gi                          | Storage size for code-server data         |
| PASSWORD             | defaultpassword               | Code-server login; change immediately     |
| **Deploy Script (deploy-code-server.sh)** |                         |                                            |
| NAMESPACE            | code-server                    | Kubernetes namespace                      |
| CODE_SERVER_PASSWORD | (required, no default)         | Password for code-server access           |
| STORAGE_SIZE         | 10Gi                          | PVC size for existing PVC                 |
| TIMEZONE             | UTC                            | Container timezone                        |
| SERVICE_TYPE         | LoadBalancer                   | Kubernetes service type                   |

**Important:** Change the default password in values.yaml or via Helm overrides to secure your environment.

## File Structure

- `main.tf`: Terraform configuration for Rackspace Spot cloudspace, node pool, and managed Kubernetes cluster. Defines variables, providers, and resources.
- `values.yaml`: Helm chart values for code-server deployment. Configures namespace, persistent volume, secrets, service, and resource limits.
- `template-values.yaml`: Template Helm values for deploy-code-server.sh with placeholders for variable substitution.
- `deploy-code-server.sh`: Interactive bash script to deploy code-server to existing infrastructure using placeholder-substituted values.
- `provision.sh`: Interactive bash script to provision infrastructure, configure kubeconfig, and deploy code-server.
- `pause.sh`: Bash script to safely pause the environment by draining pods and scaling nodes to zero, with logging to `pause.log`.
- `resume.sh`: Interactive script to resume by restoring nodes and redeploying code-server.
- `README.md`: This documentation file.

## Troubleshooting

### Common Issues

1. **Terraform init/apply fails**
   - Ensure Rackspace API credentials are correct.
   - Check internet connectivity and Rackspace API status.
   - Verify Terraform provider is installed: `terraform init`.

2. **Pods not ready in time**
   - Wait longer; increase timeout in scripts if needed (default 300s).
   - Check pod status: `kubectl get pods -n code-server`.
   - View logs: `kubectl logs <pod-name> -n code-server`.

3. **No external IP/load balancer**
   - For LoadBalancer service, ensure cloud provider supports it.
   - Fallback: `kubectl port-forward svc/code-server -n code-server 8080:80` and access at `http://localhost:8080`.
   - Check service: `kubectl get svc -n code-server`.

4. **Helm repo or upgrade fails**
   - Ensure Helm is installed and connected to cluster (`kubectl cluster-info`).
   - Check repo status: `helm repo list`.
   - Update repos: `helm repo update`.

5. **PVC not binding**
   - Verify storage class availability in cluster: `kubectl get storageclass`.
   - Check PVC events: `kubectl describe pvc code-server-pvc -n code-server`.

6. **Spot bid rejected**
   - Increase bid price; spot availability fluctuates.
   - Check current spot prices in Rackspace Spot console.

7. **Permission or authentication errors**
    - Re-enter API credentials; ensure no typos.
    - Confirm account permissions for Rackspace Spot resources.

8. **Token expired or invalid (HTTP 401/403)**
    - Check if SPOT_API_TOKEN is set and not expired.
    - For client credentials, verify SPOT_CLIENT_ID and SPOT_CLIENT_SECRET.
    - Delete cached token file: `rm -f ${XDG_RUNTIME_DIR:-/tmp}/spot_token.json`
    - Obtain fresh token from Rackspace Spot Control Panel.

9. **Namespace mismatch (HTTP 404)**
    - Ensure SPOT_ORG_NAMESPACE is set if required by your account.
    - Verify namespace exists in your Rackspace organization.

For detailed logs, check script output or log files (e.g., `pause.log`).

### Getting Help
- Review Kubernetes logs: `kubectl describe <resource> -n code-server`.
- Validate YAML: `helm template . --values values.yaml`.
- Test Terraform: `terraform plan`.

## Assumptions and Notes

- **Spot Instances**: Prices fluctuate; bids may fail if too low. Monitor costs in Rackspace Spot console.
- **Costs**: Accrue based on bid price and usage. Spot can be 70% cheaper than on-demand.
- **Persistence**: Data saved to PVC survives pauses/resumes, but not infrastructure destruction.
- **Security**: Code-server password defaults to "defaultpassword" – change via values.yaml or Helm overrides. Consider HTTPS with ingress/SSL.
- **Idempotency**: Scripts handle re-runs safely, but manual Terraform changes may cause drift.
- **Regions**: Primary supports us-west, us-central, us-east, eu-west; adjust in main.tf and provision.sh if needed.
- **Dependencies**: Assumes Helm chart "code-server" and repo; customize values.yaml for specific needs.
- **Environment Cleanup**: To destroy, use `terraform destroy` after pausing.
- **Testing**: Dry-run suggestions in comments (e.g., `helm install --dry-run`).
- **Updates**: Check for Helm chart updates via `helm repo update` periodically.
- **API Base URL**: All API calls now use a centralized `SPOT_API_BASE` environment variable (default: https://spot.rackspace.com/api/v1).
- **Dynamic Menus**: Region and server class selections are now dynamically populated from the Rackspace Spot API.
- **Method Validation**: GET/POST methods are validated per official API documentation.
- **Authentication**: Token-based auth flow is implemented consistently across all scripts.
- **Error Handling**: Improved HTTP status validation and error reporting.