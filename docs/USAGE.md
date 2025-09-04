# Usage Guide for Remote VS Code Environment on Rackspace Spot

This guide provides detailed usage instructions for setting up and managing a remote VS Code (code-server) environment on Rackspace Spot infrastructure. It builds on the README.md documentation with step-by-step guides, advanced configuration examples, and extended troubleshooting information.

## Overview

This environment leverages Terraform for infrastructure provisioning, Helm for application deployment, and interactive scripts for simplified setup. The system supports both full provisioning and deployment to existing infrastructure, with options for cost-optimized Spot instances.

## Interactive Menu Walkthroughs

The scripts use bash `select` commands to present numbered menus for key configuration options. This simplifies the deployment process without requiring extensive command-line knowledge.

### Provisioninganeamente Script Menus ([`provision.sh`](provision.sh))

This script handles full infrastructure provisioning and initial code-server deployment.

**Step 1: API Credentials Input**
```
Enter RACKSPACE_API_KEY (must be set): [your-api-key]
Enter RACKSPACE_API_SECRET (must be set): [your-api-secret]
```
- Required fields; no defaults. Obtain from Rackspace Spot Control Panel > Account > API Key Management.

**Step 2: Region Selection**
```
Select the REGION for deployment:
Supported regions:
1. us-west  - Western US region (e.g., Seattle area)
2. us-central - Central US region (e.g., Chicago)
3. us-east  - Eastern US region (e.g., Dallas - DFW)
4. eu-west  - Western Europe region (e.g., London)
Enter your choice (1-4):
```
- Enter the number corresponding to your preferred region.
- Default if no selection: us-east

**Step 3: Spot Instance Bid Price**
```
Enter BID_PRICE [0.03]:
```
- Numeric value in USD per hour.
- Must be > 0.0 and <= 1.0
- Default: 0.03 (recommended starting point)

**Step 4: Node Count**
```
Enter NODE_COUNT [1]:
```
- Number of worker nodes in the cluster.
- Range: 1-10
- Default: 1

**Step 5: Server Flavor Selection**
```
Select the SERVER_FLAVOR for spot instances:
Supported flavors with resource specs:
1. m3.medium  - 1 vCPU, 4GB RAM (cost-effective for lightweight workloads)
2. m3.large   - 2 vCPU, 8GB RAM (balanced performance and cost)
3. m3.xlarge  - 4 vCPU, 16GI RAM (high-performance for demanding applications)
Enter your choice (1-3):
```
- Select based on your workload requirements.
- Default: m3.large

**Step 6: Kubeconfig Path**
```
Enter KUBECONFIG_PATH [/home/user/.kube/config]:
```
- Path to store the generated kubeconfig file.
- Default: ~/USER/.kube/config (expanded)

**Example Complete Run:**
```
./provision.sh
Enter RACKSPACE_API_KEY: xxxxxx
Enter RACKSPACE_API_SECRET: yyyyyy
Select the REGION for deployment:
1. us-west
2. us-central
3. us-east
4. eu-west
Enter your choice: 3
Enter BID_PRICE [0.03]: 0.04
Enter NODE_COUNT [1]: 2
Select the SERVER_FLAVOR...
Enter your choice: 2
Enter KUBECONFIG_PATH [/home/user/.kube/config]: /path/to/config
Initializing Terraform...
Applying Terraform configuration...
Setting KUBECONFIG...
Installing code-server via Helm...
code-server is ready! Access it at: http://123.45.67.89
```

### Deploy Script Menus ([`deploy-code-server.sh`](deploy-code-server.sh))

This script deploys code-server to an existing Kubernetes cluster.

**Step 1: Kubeconfig Path Selection**
```
Select KUBECONFIG_PATH (kubeconfig file for cluster access):
  1) ~/.kube/config
  2) /etc/kubernetes/admin.conf
  3) Custom path
  4) Cancel
Enter your choice:
```
- Choose 1, 2, or 3 to specify the kubeconfig location.
- Select 3 for custom path and enter it when prompted.
- Script validates the file exists.

**Step 2: Namespace**
```
Enter NAMESPACE [code-server]:
```
- Kubernetes namespace for deployment.
- Default: code-server
- Must be lowercase alphanumeric with hyphens.

**Step 3: Password (Hidden Input)**
```
Enter CODE_SERVER_PASSWORD:
```
- No echo; type securely.
- No default; required field.

**Step 4: Storage Size**
```
Enter STORAGE_SIZE [10Gi]:
```
- Format: XGi or XMi (e.g., 20Gi, 5Gi)
- Default: 10Gi

**Step 5: Timezone Selection**
```
Select TIMEZONE (affects code-server timestamps and logs):
  1) UTC
  2) America/New_York
  3) Europe/London
  4) Asia/Tokyo
  5) America/Los_Angeles
  6) Europe/Paris
Enter your choice:
```
- Choose timezone number.
- Affects container and code-server timezone.

**Step 6: Service Type Selection**
```
Select SERVICE_TYPE (determines how code-server is exposed):
  1) LoadBalancer
  2) ClusterIP
Enter your choice:
```
- LoadBalancer: External public IP access.
- ClusterIP: Internal cluster access only.

**Example Complete Run:**
```
./deploy-code-server.sh
Select KUBECONFIG_PATH...
Enter your choice: 1
Enter NAMESPACE [code-server]: my-namespace
Enter CODE_SERVER_PASSWORD: [hidden]
Enter STORAGE_SIZE [10Gi]: 20Gi
Select TIMEZONE...
Enter your choice: 2
Select SERVICE_TYPE...
Enter your choice: 1
Using KUBECONFIG: /home/user/.kube/config
...
SUCCESS: code-server is ready! Access it at: http://123.45.67.89
```

## Market Pricing and Bidding Strategies

Rackspace Spot pricing is dynamic, based on real-time supply and demand for cloud resources. Understanding market dynamics helps optimize costs and availability for your deployments.

### Market Pricing Explanation

Spot prices fluctuate hourly and are determined by:
- **Demand**: High usage of specific instance types increases prices.
- **Supply**: Availability of spare capacity affects pricing.
- **Region/Zones**: Prices vary by geographic location; some AZs offer better rates.

Spot instances typically offer 50-70% savings over on-demand pricing, but can be pre-empted when demand exceeds supply or your bid is outbid.

### Bidding Strategies

Select a bidding approach based on your workload's tolerance for interruption and cost goals:

- **Conservative** (Recommended for stable workloads)
  - Bid: Slightly below on-demand (~10-20% discount)
  - Pros: High availability, low pre-emption risk
  - Use: Critical applications, long-running jobs

- **Balanced** (Balanced cost and availability)
  - Bid: Moderate discount (~30-50%)
  - Pros: Good savings with reasonable uptime
  - Use: Development environments, batch processing

- **Aggressive** (Maximum cost savings)
  - Bid: Low discount (~70-80%)
  - Pros: Highest possible savings
  - Cons: Frequent pre-emption
  - Use: Fault-tolerant, stateless workloads

- **Custom** (Flexible approach)
  - Define exact prices or percentages via API
  - Pros: Tailored to specific needs
  - Use: Advanced users optimizing based on patterns

**Implementation in Scripts**: Set BID_PRICE when running [`provision.sh`](provision.sh). Start with conservative strategy for initial deployments. Monitor usage in Rackspace Spot console and adjust based on pre-emption history.

## Advanced Configuration

### Customizing Helm Values

The deployment uses Helm charts from the PascalIske/code-server repository. Override default settings by modifying `values.yaml` or using Helm parameters.

#### Example: Custom Resource Limits
```yaml
# In values.yaml
resources:
  limits:
    cpu: 2
    memory: 4Gi
  requests:
    cpu: 500m
    memory: 1Gi
```

#### Example: Additional Environment Variables
```yaml
# In values.yaml
extraEnvVars:
  - name: CUSTOM_VAR
    value: "custom-value"
```

#### Example: Ingress Configuration (for HTTPS)
```yaml
# In values.yaml
ingress:
  enabled: true
  className: nginx
  hosts:
    - host: code-server.example.com
      paths:
        - path: /
          pathType: Prefix
  tls:
    - secretName: tls-secret
      hosts:
        - code-server.example.com
```

#### Deploying with Custom Values
```bash
# Using deploy-code-server.sh with your modified values.yaml
cp values.yaml custom-values.yaml
# Edit custom-values.yaml as needed
helm upgrade --install code-server pascaliske/code-server -f custom-values.yaml
```

### Namespace Management

- Default namespace: `code-server`
- Custom namespace: Specify via script prompt or Helm `--namespace` flag
- Multi-tenancy: Deploy separate instances in different namespaces
  ```bash
  ./deploy-code-server.sh  # Choose custom namespace
  kubectl get namespaces   # Verify creation
  ```

### Security Configurations

#### Password Management
- Default password: Change immediately in production
- Generated password strength: Minimum 8 characters recommended
- Override via Helm:
  ```bash
  helm upgrade --set='auth.password=your-strong-password' code-server pascaliske/code-server
  ```

#### Network Security
- LoadBalancer: Exposes port 80 externally; configure firewall rules
- ClusterIP: Internal only; secure with RBAC
- SSH tunnel access: Use `kubectl port-forward` for encrypted local access

### Storage Customizations

#### PVC Size and Class
- Default: 10Gi, using default storage class
- Customize in values.yaml:
  ```yaml
  persistence:
    size: 50Gi
    storageClass: "fast-ssd"  # Replace with available class
  ```

#### Backup and Recovery
- PVC data persists during pause/resume cycles
- Backup PVC data:
  ```bash
  kubectl cp code-server-pod:/home/coder/workspace/ backup/ -n code-server
  ```

## Troubleshooting

This section expands on the README.md troubleshooting with additional solutions and debugging steps.

### Rackspace Spot Specific Issues

This subsection addresses common issues unique to Rackspace Spot infrastructure.

1. **API Token Issues**
   - **Symptoms**: "Invalid credentials" or authentication failures during setup
   - **Solutions**:
     - Verify API key and secret in Rackspace Spot Control Panel under Account settings
     - Ensure account has Spot instance permissions enabled
     - Check for token expiration and regenerate if needed
     - Clean cache: `rm -rf ~/.terraform.d/`

2. **Market Availability Problems**
   - **Symptoms**: Bid rejected due to "insufficient capacity" or high spot prices
   - **Debug Steps**:
     - Check current spot prices in Rackspace Spot console pricing dashboard
     - Verify instance type availability in selected regions
     - Try alternative availability zones
   - **Solutions**:
     - Increase BID_PRICE by 20-50% in [`provision.sh`](provision.sh)
     - Switch to different SERVER_FLAVOR with better availability
     - Monitor spot pricing trends and schedule deployments during off-peak hours

3. **Pre-emption Scenarios**
   - **Symptoms**: Instances terminate without warning or during use
   - **Debug**:
     - Check webhook logs for pre-emption notices
     - Review Rackspace Spot console for termination events
     - Examine Kubernetes events: `kubectl get events -n code-server`
   - **Solutions**:
     - Enable pre-emption webhooks as described in Pre-emption Handling section
     - Implement checkpointing in code-server (save frequently)
     - Use `resume.sh` to redeploy after termination
     - Switch to conservative bidding strategy to reduce termination frequency


### Infrastructure Deployment Issues
1. **Terraform Initialization Failures**
   - **Symptoms**: "terraform init" fails with network or authentication errors
   - **Solutions**:
     - Verify internet connectivity to HashiCorp releases
     - Check Terraform version: `terraform --version` (must be >= 1.0.0)
     - Clear Terraform cache: `rm -rf .terraform/` and retry
     - Use proxy if behind firewall: Set `HTTP_PROXY` environment variable

2. **Infrastructure Provisioning Timeouts**
   - **Symptoms**: Deployment hangs after 15-20 minutes
   - **Solutions**:
     - Increase Terraform timeout in main.tf (default: 30 minutes)
     - Verify Spot instance availability in Rackspace Spot console
     - Check Spot bid price adequacy: Increase by 5-10%
     - Monitor Rackspace Spot Control Panel for creation progress

3. **LoadBalancer External IP Stuck at Pending**
   - **Symptoms**: `kubectl get svc` shows EXTERNAL-IP: "<pending>"
   - **Debug Steps**:
     1. Check LoadBalancer service details: `kubectl describe svc code-server -n code-server`
     2. Verify cloud provider supports LoadBalancer (Rackspace Spot does)
     3. Check account quotas for public IPs
     4. Wait additional 10-15 minutes (DNS propagation)
   - **Manual Fallback**: Use ClusterIP with port-forwarding

### Kubernetes Cluster Issues

1. **Node Not Ready Status**
   - **Debug**: `kubectl describe node <node-name>`
   - **Common Causes**:
     - Network configuration issues
     - Rackspace Spot API connectivity problems
     - Spot instance termination by platform
   - **Recovery**:
     - Scale nodes: Edit main.tf `node_count = 0`, apply, then set back to 1
     - Check Rackspace Spot console for infrastructure health

2. **PVC NotBinding Status**
   - **Debug**: `kubectl describe pvc code-server-pvc -n code-server`
   - **Debug Commands**:
     ```bash
     kubectl get storageclass                    # Available classes
     kubectl get pv                             # Persistent volumes
     kubectl describe storageclass <class-name> # Class details
     ```
   - **Solutions**:
     - Set correct storageClassName in values.yaml to match cluster capabilities
     - Ensure PVC size doesn't exceed class limits
     - For Rackspace, use "rackspace-block-v6" class

3. **Pod Scheduling Failures**
   - **Debug**: `kubectl describe pod <pod-name> -n code-server`
   - **Common Causes**:
     - Insufficient node resources (CPU/memory)
     - Taints on nodes preventing scheduling
     - Affinity rules not met
   - **Solutions**:
     - Increase server flavor in main.tf
     - Check node taints: `kubectl get nodes --show-labels --show-kind`
     - Adjust resource requests/limits in values.yaml

### Application Issues

1. **Code-Server Not Accessible**
   - **LoadBalancer Check**:
     ```bash
     kubectl port-forward svc/code-server 8080:80 -n code-server
     # Then access http://localhost:8080
     ```
   - **Service Health**: `kubectl get endpoints -n code-server`
   - **Pod Logs**: `kubectl logs -f deployment/code-server -n code-server`

2. **Authentication Failures**
   - **Symptoms**: "Invalid password" or authentication loop
   - **Debug**: Check Helm release values
     ```bash
     helm get values code-server -n code-server
     ```
   - **Reset Password**: Update via Helm upgrade or secrets edit
   - **Verify Secret**: `kubectl get secret code-server-password -n code-server -o yaml`

3. **Container Timezone Issues**
   - **Verify**: Login to pod and check `date` output
   - **Override**: Set TZ environment variable in values.yaml
     ```yaml
     extraEnvVars:
       - name: TZ
         value: America/New_York
     ```

4. **Mac Compatibility Issues**
   - **BuildKit Support**: Ensure Docker Desktop or container runtime supports BuildKit
   - **File Permissions**: Code-server runs as vscode user (UID 1000); ensure file ownership
   - **VS Code Extensions**: Some may require additional dependencies

### Performance Optimization

1. **Slow Startup Times**
   - **Debug**: Pod logs during startup: `kubectl logs -f code-server-xxxxx -n code-server`
   - **Optimize**:
     - Use faster storage class if available
     - Increase resource requests (CPU/memory)
     - Pre-install frequently used extensions

2. **Memory Usage High**
   - **Monitor**: `kubectl top pods -n code-server`
   - **Mitigate**:
     - Close unused VS Code tabs
     - Install memory-efficient extensions
     - Adjust resource limits in values.yaml

### Logging and Monitoring

1. **Access Detailed Logs**
   - **Pod Logs**: `kubectl logs -f code-server-xxxxx -n code-server --tail=100`
   - **Containerd Logs**: `kubectl debug node/node-name -it --image=busybox -- chroot /host journalctl -u kubelet`

2. **Terraform Logs**
   - **Debug Mode**: Set TF_LOG=DEBUG before running terraform
   - **State Inspection**: `terraform state list` to see managed resources

3. **Helm Release Status**
   - **Release Info**: `helm status code-server -n code-server`
   - **History**: `helm history code-server -n code-server`
   - **Rollback**: `helm rollback code-server <revision> -n code-server`

### Environment Cleanup

1. **Safe Removal**
   ```bash
   ./pause.sh        # Scale to zero
   terraform destroy # Remove infrastructure
   kubectl delete ns code-server  # Clean namespace
   ```

2. **Force Removal (if stuck)**
   ```bash
   kubectl delete ns code-server --force --grace-period=0
   terraform destroy --force
   ```

### Getting Advanced Help

- **Rackspace Spot Support**: Cloud Control Panel > Support > Create Ticket
- **Helm Chart Issues**: PascalIske/code-server GitHub repository
- **Kubernetes Community**: kubernetes.io/docs/ and community forums

## Pre-emption Handling

Rackspace Spot instances may be terminated automatically with advance notice. Implement webhooks and recovery strategies to handle pre-emptions gracefully.

### Webhook Setup

Configure webhooks in the Rackspace Spot Control Panel to receive termination notifications:

1. Access the console and navigate to Settings > Webhooks.
2. Create a new webhook with POST method and endpoint (e.g., https://your-domain/spot-webhook).
3. Subscribe to "Instance Pre-emption" event type.
4. Set appropriate authentication tokens.

### 5-Minute Pre-emption Warnings

Notifications provide 5-minute advance warning for graceful shutdown. Use this period to:
- Save current state to persistent storage.
- Complete in-progress operations.
- Log pre-emption events for analysis.
- Provision backup instances if configured.

### Recovery Strategies

- **Manual Recovery**: Use `resume.sh` script after pre-emption to restore environment.
- **Automated Scaling**: Configure Kubernetes autoscaling to handle node replacements.
- **Checkpointing**: Regularly save application state for quick restart on new instances.
- **Multi-AZ Deployment**: Spread workloads across availability zones to reduce impact.

Before submitting tickets, gather diagnostic info:
- Terraform version and plan output
- kubectl cluster-info dump (redact sensitive data)
- Helm release describe: `helm get all code-server -n code-server`
- Pod and service descriptions

This comprehensive guide should cover most deployment and operational scenarios. Start with the README.md quick start, use this guide for details during installation, and refer here for advanced needs and troubleshooting.