# Contributing

This repository contains scripts to provision and manage Rackspace Spot resources.
This CONTRIBUTING file explains how to run the scripts and provide credentials.

## Required environment variables

You must set either:
- `SPOT_API_TOKEN` (preferred), or
- `SPOT_CLIENT_ID` and `SPOT_CLIENT_SECRET` (client credentials flow)

Also required:
- `SPOT_ORG_NAMESPACE` — your organization namespace
- Optionally `SPOT_API_BASE` — defaults to `https://spot.rackspace.com/api/v1`

## Quick start

1. Copy `.env.example` to `.env` and fill values.
2. Run `./provision.sh --dry-run` to validate.
3. Run `./scripts/sanity-check.sh` to verify connectivity.

## Running scripts

### Provisioning infrastructure
```bash
./provision.sh [--dry-run]
```

The provision script will:
- Prompt for required variables with defaults
- Initialize and apply Terraform for infrastructure
- Set up KUBECONFIG
- Install code-server via Helm
- Wait for pods to be ready
- Provide access instructions

### Deploying code-server
```bash
./deploy-code-server.sh [--dry-run]
```

The deploy script will:
- Prompt for required values
- Validate inputs
- Set namespace
- Add Helm repo
- Generate values.yaml
- Run Helm install
- Handle service access

### Pausing the environment
```bash
./pause.sh
```

### Resuming the environment
```bash
./resume.sh
```

## Validation checks

### Sanity check script
Run the sanity check script to verify connectivity and basic functionality:
```bash
./scripts/sanity-check.sh
```

### Manual validation
After deployment, verify the environment with these commands:

1. Check cluster nodes:
   ```bash
   kubectl get nodes
   ```

2. Check persistent volume claims:
   ```bash
   kubectl get pvc -n code-server
   ```

3. Check services:
   ```bash
   kubectl get svc -n code-server
   ```

## Development

- Run `shellcheck` on bash scripts before committing.
- Create one logical change per commit and include unit tests or manual test steps.
- Follow the existing code style and patterns.
- Update README.md and this CONTRIBUTING.md when adding new features.

## Terraform Configuration
The main.tf uses the `spot_token` variable for authentication.

Pass the token via environment:
```bash
export TF_VAR_spot_token="$SPOT_API_TOKEN"
```

Or via .tfvars:
Create terraform.tfvars with:
```
spot_token = "your-token-here"
```

Run terraform commands as usual. The scripts will prompt for the token if not set via TF_VAR_spot_token.
