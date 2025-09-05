# Rackspace Spot Tool - Issues and Improvements (Updated with Research)

## Critical Issues (Must Fix)

### 1. Terraform Configuration Issues
- [ ] **Invalid Terraform Provider**: `main.tf` references `rackerlabs/rackspace` provider which doesn't exist
  - **Fix**: Use correct provider `rackerlabs/spot` 
  - **Research**: The correct provider is `rackerlabs/spot` available at https://registry.terraform.io/providers/rackerlabs/spot/latest
  - **Provider Configuration**:
    ```hcl
    terraform {
      required_providers {
        spot = {
          source = "rackerlabs/spot"
          version = "~> 0.1.4"
        }
      }
    }
    
    provider "spot" {
      token = var.rackspace_spot_token
    }
    ```
  - **Location**: `main.tf:8-12`

- [ ] **Invalid Resource Types**: Using non-existent Terraform resources
  - **Fix**: Replace with correct Rackspace Spot resources:
    - `rackspace_spot_cloudspace` → `spot_cloudspace`
    - `rackspace_spot_node_pool` → `spot_spotnodepool` 
    - `rackspace_kubernetes_cluster` → Use `spot_cloudspace` (includes Kubernetes)
  - **Available Resources**:
    - `spot_cloudspace`: Creates managed Kubernetes cluster with control plane
    - `spot_spotnodepool`: Creates spot-priced node pools  
    - `spot_ondemandnodepool`: Creates on-demand node pools
  - **Location**: `main.tf:85-110`

- [ ] **Hardcoded Kubeconfig Output**: Terraform output returns static path instead of actual kubeconfig
  - **Fix**: Use `spot_kubeconfig` data source to retrieve actual kubeconfig
  - **Implementation**:
    ```hcl
    data "spot_kubeconfig" "main" {
      cloudspace_name = spot_cloudspace.main.cloudspace_name
    }
    
    output "kubeconfig" {
      description = "Kubeconfig content for the cluster"
      value = data.spot_kubeconfig.main.raw
      sensitive = true
    }
    ```
  - **Location**: `main.tf:114`

### 2. API Integration & Authentication

- [ ] **API Base URL**: Current scripts use placeholder API base URL
  - **Fix**: Use correct Rackspace Spot API base URL: `https://spot.rackspace.com/api/v1`
  - **Authentication**: Token-based authentication via dashboard at https://spot.rackspace.com
  - **Token Source**: Navigate to "API Access" > "Terraform" section in Rackspace Spot dashboard
  - **Location**: `scripts/helpers.sh:7`

- [ ] **Organization Namespace**: Scripts reference undefined organization namespace concept
  - **Fix**: This appears to be a custom concept not found in Rackspace Spot documentation
  - **Research**: Rackspace Spot uses simple token-based auth without organization namespaces
  - **Action**: Remove organization namespace logic or clarify if this is for different service
  - **Location**: Multiple scripts

### 3. Correct Resource Configuration

- [ ] **Server Classes**: Scripts contain hardcoded server class lists
  - **Research**: Available server classes from `spot_serverclasses` data source:
    - General Purpose: `gp.vs1.small-dfw`, `gp.vs1.medium-dfw`, `gp.vs1.large-dfw`, etc.
    - Compute Heavy: Similar naming pattern with `ch.` prefix
    - Memory Heavy: Similar naming pattern with `mh.` prefix  
    - GPU: `gpu.` prefix for GPU-enabled instances
  - **Fix**: Use `spot_serverclasses` data source to fetch available classes dynamically
  - **Location**: `provision.sh`, `deploy-code-server.sh`

- [ ] **Regions**: Scripts contain hardcoded region lists  
  - **Research**: Available regions from `spot_regions` data source:
    - US regions: `us-central-dfw-1`, `us-east-iad-1`, `us-west-sjc-1`
    - International: `eu-west-lon-1`, etc.
  - **Fix**: Use `spot_regions` data source to fetch available regions dynamically
  - **Location**: `provision.sh:127`, `deploy-code-server.sh:139`

### 4. Script Structure Issues

- [ ] **Duplicate Main Function**: `provision.sh` has main() function defined twice
  - **Fix**: Merge or remove duplicate function definition
  - **Location**: `provision.sh:29` and later in file

- [ ] **Missing Error Handling**: Scripts exit without cleanup when errors occur
  - **Fix**: Add proper trap handlers and cleanup functions
  - **Location**: All shell scripts

- [ ] **Helm Repository Inconsistency**: Scripts use different Helm repos (`coder-saas` vs `pascaliske`)
  - **Fix**: Research shows code-server is commonly available via multiple repos
  - **Recommendation**: Standardize on one reliable repository
  - **Location**: `provision.sh:456`, `deploy-code-server.sh:203`

## High Priority Issues

### 5. Kubeconfig Management

- [ ] **Kubeconfig Retrieval**: Current implementation attempts to use Terraform output
  - **Fix**: Use `spot_kubeconfig` data source which provides:
    - Raw kubeconfig content via `.raw` attribute
    - Structured access via `.kubeconfigs[0].host`, `.kubeconfigs[0].token`
    - OIDC integration for automatic token refresh
  - **Implementation**: Replace manual kubeconfig handling with data source
  - **Location**: `provision.sh`, `deploy-code-server.sh`

### 6. Incomplete Helper Functions

- [ ] **get_serverclasses Function**: Function is truncated/incomplete in helpers.sh
  - **Fix**: Complete the function to call `/serverclasses?region=<region>` endpoint
  - **API Details**: Returns JSON with serverclass names, resources (CPU, memory), pricing
  - **Location**: `scripts/helpers.sh:131`

- [ ] **Cost-effectiveness Calculation**: Function exists but may have calculation errors
  - **Fix**: Verify formula: `score = price_per_hour / (vcpu_weight * vCPUs + mem_weight * memory_gb + gpu_weight * gpu_count)`
  - **Research**: Rackspace Spot uses market-based pricing with bid mechanisms
  - **Location**: `scripts/helpers.sh`

### 7. Configuration File Issues

- [ ] **Values File Mismatch**: `values.yaml` and `template-values.yaml` have inconsistent structure
  - **Fix**: Research shows code-server Helm charts vary by repository
  - **Action**: Standardize on one chart and align both files to same schema  
  - **Location**: `values.yaml`, `template-values.yaml`

## Rackspace Spot Service Details (For Reference)

### Service Overview
- **What it is**: Auction-based cloud infrastructure with managed Kubernetes
- **Pricing**: Market-driven spot pricing starting from $0.001/hr
- **Infrastructure**: Uses spare capacity from Rackspace global datacenters
- **Management**: Fully managed Kubernetes control planes (free)

### Key Concepts
- **Cloudspace**: Logical unit containing Kubernetes cluster + infrastructure
- **Spotnodepool**: Group of spot-priced worker nodes  
- **Bidding**: Users set maximum bid prices, pay market rate
- **Preemption**: 5-minute warning when instances need to be reclaimed

### Available Resources
1. **spot_cloudspace**: Creates managed K8s cluster
   - Includes control plane (free)
   - Supports HA control plane for production
   - CNI options: calico, cilium, byocni
   - Kubernetes versions: 1.29.6, 1.30.10, 1.31.1

2. **spot_spotnodepool**: Spot-priced worker nodes
   - Requires bid_price in USD (3 decimal places)
   - Supports autoscaling (min_nodes, max_nodes)
   - Node labels, annotations, taints supported

3. **spot_ondemandnodepool**: Fixed-price worker nodes
   - Alternative to spot pricing for stable workloads
   - Same configuration options as spotnodepool

### Data Sources
- **spot_regions**: Lists available regions
- **spot_serverclasses**: Lists available instance types with filtering
- **spot_kubeconfig**: Retrieves kubeconfig for cluster access
- **spot_cloudspace**: Gets cloudspace information

### Authentication
- Token-based authentication only
- Tokens obtained from dashboard: https://spot.rackspace.com → API Access
- No OAuth or organization namespace concepts

## Implementation Notes

### Terraform Provider Usage
```hcl
# Correct provider configuration
terraform {
  required_providers {
    spot = {
      source = "rackerlabs/spot"
    }
  }
}

# Provider configuration
provider "spot" {
  token = var.rackspace_spot_token
}

# Example cloudspace
resource "spot_cloudspace" "example" {
  cloudspace_name = "my-cluster"
  region = "us-central-dfw-1"
  hacontrol_plane = false
  kubernetes_version = "1.31.1"
  cni = "calico"
}

# Example spot node pool  
resource "spot_spotnodepool" "example" {
  cloudspace_name = spot_cloudspace.example.cloudspace_name
  server_class = "gp.vs1.medium-dfw"
  bid_price = 0.012
  autoscaling = {
    min_nodes = 2
    max_nodes = 8
  }
}

# Get kubeconfig
data "spot_kubeconfig" "example" {
  cloudspace_name = spot_cloudspace.example.cloudspace_name
}
```

### Code-server Deployment
- Rackspace Spot provides managed Kubernetes, not code-server specifically  
- Code-server deployment via Helm should work on any K8s cluster
- Focus on proper Kubernetes cluster provisioning first

## Medium Priority Issues

### 8. User Experience Problems

- [ ] **Complex Interactive Menus**: Menu selection logic is overly complex
  - **Fix**: Simplify menu system with helper functions
  - **Location**: `provision.sh:137-170`, multiple other locations

- [ ] **Verbose Output**: Scripts produce too much output, making errors hard to spot
  - **Fix**: Implement log levels (ERROR, WARN, INFO, DEBUG)
  - **Location**: All scripts

- [ ] **Inconsistent Input Validation**: Some inputs validated, others not
  - **Fix**: Add validation functions for all user inputs
  - **Location**: All scripts with user prompts

### 9. Code Quality Issues

- [ ] **Long Functions**: Many functions exceed 50 lines, making them hard to maintain
  - **Fix**: Break down large functions into smaller, focused ones
  - **Location**: `provision.sh:main()`, `deploy-code-server.sh:main()`

- [ ] **Magic Numbers**: Timeout values and other constants hardcoded
  - **Fix**: Define constants at top of scripts
  - **Location**: `provision.sh:455`, `deploy-code-server.sh:295`

- [ ] **Inconsistent Variable Naming**: Mix of camelCase and snake_case
  - **Fix**: Standardize on snake_case for shell scripts
  - **Location**: Throughout all scripts

## Low Priority Improvements

### 10. Security and Reliability

- [ ] **Token Storage**: Tokens stored in predictable locations
  - **Fix**: Use more secure temporary storage with proper permissions
  - **Location**: `scripts/helpers.sh:7`

- [ ] **Command Injection Risk**: Some variables not properly quoted
  - **Fix**: Quote all variable expansions
  - **Location**: Various locations in all scripts

- [ ] **Insecure Defaults**: Default password is "defaultpassword"
  - **Fix**: Generate random password or force user to set one
  - **Location**: `values.yaml:16`

## Implementation Priority

### Phase 1 (Critical - Complete First)
- [x] Fix Terraform provider and resource types
- [x] Resolve duplicate function definitions
- [x] Fix API integration and authentication
- [x] Complete truncated helper functions

### Phase 2 (High Priority)
- [x] Implement proper kubeconfig management
- [x] Fix configuration file mismatches
- [x] Simplify user interactions
- [x] Add proper error handling

### Phase 3 (Medium Priority)
- [x] Improve code quality and structure
- [x] Add comprehensive input validation
- [x] Implement proper logging
- [x] Security improvements

### Phase 4 (Enhancement)
- [x] Add unit tests
- [x] Update documentation
- [x] Performance optimizations
- [x] Additional features