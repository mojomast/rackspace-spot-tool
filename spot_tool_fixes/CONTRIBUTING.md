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
2. Run `./scripts/provision.sh --dry-run` to validate.
3. Run `./scripts/sanity-check.sh` to verify connectivity.

## Development

- Run `shellcheck` on bash scripts before committing.
- Create one logical change per commit and include unit tests or manual test steps.
