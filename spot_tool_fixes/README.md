# rackspace-spot-tool (patched)
This bundle contains suggested script implementations to interface with Rackspace Spot API.
Place the `scripts/` directory into your repository root and follow CONTRIBUTING.md.

Main scripts:
- `scripts/helpers.sh` - token helper and API wrapper
- `scripts/provision.sh` - interactive provisioning flow (supports --dry-run)
- `scripts/sanity-check.sh` - quick validation checks
- `scripts/pause.sh` / `scripts/resume.sh` - scale nodepools

Configuration:
- Copy `.env.example` to `.env` and export or source it before running scripts.
