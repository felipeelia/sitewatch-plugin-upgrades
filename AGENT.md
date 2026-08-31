# Agent guidance: sitewatch-plugin-upgrades

This repo is a **reusable GitHub Action** for SiteWatch projects hosted on **GitHub**. Consumer projects use it in their workflows with `uses: felipeelia/sitewatch-plugin-upgrades@trunk` (or a tag). The action runs in the **consumer’s workspace** (after they run `actions/checkout`): it performs Composer-based plugin upgrades, builds a PR description, pushes a branch, and opens PRs against the consumer’s branches (e.g. production, staging).

**Keep this file updated:** When you add, remove, or rename actions, scripts, or key files—or change conventions—update **AGENT.md** so the repo layout, “Key files to touch”, and conventions stay accurate.

## Repo layout

| Path | Purpose |
|------|---------|
| `action.yml` | Root composite action: backwards-compatible entry that runs the Plugin Upgrades script from `plugin-upgrades/`. Consumers using `uses: owner/repo@ref` (no path) get this. |
| `plugin-upgrades/action.yml` | Plugin Upgrades composite action: inputs, PHP setup, script invocation, and `gh pr create` steps. Used when consumers reference `owner/repo/plugin-upgrades@ref`. |
| `plugin-upgrades/plugin-upgrades-merge-request.sh` | Plugin Upgrades logic: Composer update with start/end markers, parsing upgrade output, paid-plugins version diff (optional), and writing the PR description to a temp file used by the action. |
| `vuln-plugin-update/action.yml` | Vuln plugin update composite action: inputs (including optional `update_kind`), PHP + Composer auth, script run, Create PRs step. |
| `vuln-plugin-update/vuln-plugin-update-and-mr.sh` | Vuln update logic: parse items (comma- or newline-separated), run composer/paid_plugin updates, write PR description(s) and manifest for action. `VULN_UPDATE_KIND` (`vulnerable`/`on_demand`) sets title/commit/branch prefixes and writes them to `GITHUB_ENV`. |
| `README.md` | Consumer-facing docs: actions table, usage, inputs, Composer auth, behaviour. |

Each action lives in its own directory with `action.yml` and script(s) directly in that directory (no `scripts/` subfolder). Consumers add a workflow that checks out their repo and calls an action with the desired inputs (see **README.md**). The Plugin Upgrades action expects a Composer-based project (e.g. `composer.json` at repo root). No separate token is required for push/PR when targeting the same repo; use `composer_github_token` (or `composer_auth`) only for private packages.

## Conventions when editing

### Shell scripts

- Shebang: `#!/bin/bash` or `#!/usr/bin/env bash`.
- Use `set -eo pipefail` at the top.
- Indent with **tabs**.
- Configuration via **environment variables** (UPPER_SNAKE_CASE), with defaults using `${VAR:-default}` or `${VAR-default}` as appropriate.
- Validate required env vars early and exit with a clear error message if missing.
- Scripts run in the **consumer project’s workspace** (the action is invoked after the consumer’s checkout). Assume `composer.json`, Composer, and optional plugin/paid-plugin paths exist in the consumer repo, not in this repo.
- Keep scripts self-contained; avoid depending on other repos or tools beyond what the action provides (`GITHUB_ACTION_PATH`, `runner.temp`, and env vars set from action inputs).

### GitHub Action (action.yml)

- Inputs are the public API; preserve backward compatibility. Prefer adding new optional inputs over changing or removing existing ones.
- The script is run from `$GITHUB_ACTION_PATH/plugin-upgrades-merge-request.sh` (when using `plugin-upgrades/`) or `$GITHUB_ACTION_PATH/plugin-upgrades/plugin-upgrades-merge-request.sh` (when using root) so path references stay correct when the action is used from another repo.
- PR description is written to a file (e.g. `${{ runner.temp }}/pr-description.md`) and passed to `gh pr create --body-file`; the script must not assume a fixed path unless the action sets `PR_DESCRIPTION_FILE`.
- Default variables (e.g. `prod_branch`, `staging_branch`) are set in `action.yml` so consumers only override when needed.

### Adding a new automation or script

- New **action** (new entry point): add a new directory (e.g. `vuln-plugin-update/`) with its own `action.yml` and script(s) directly in that directory (no `scripts/` subfolder). Add a section in README and a row in the Repo layout table above; ensure scripts follow the shell conventions and run in the consumer workspace. Consumers will use `uses: owner/repo/action-name@ref`.
- New **script** used by an existing action: add it in that action's directory, invoke it from that action's `action.yml` using `GITHUB_ACTION_PATH`, and document any new inputs or env vars in README and the action's `action.yml`.

## Key files to touch

- **Root action (backwards compat)**: `action.yml` (script path to `plugin-upgrades/plugin-upgrades-merge-request.sh`).
- **Plugin Upgrades action**: `plugin-upgrades/action.yml` (inputs, steps, env passed to script and `gh pr create`).
- **Plugin Upgrades script**: `plugin-upgrades/plugin-upgrades-merge-request.sh` (Composer update, parsing, PR body generation, paid-plugins logic).
- **Vuln plugin update action**: `vuln-plugin-update/action.yml` (inputs including optional `update_kind`, Create PRs step for single_branch and branch_per_env).
- **Vuln plugin update script**: `vuln-plugin-update/vuln-plugin-update-and-mr.sh` (update_items parsing, composer_dir, PR description + manifest output, `VULN_UPDATE_KIND` title/branch prefixes).
- **Consumer-facing docs**: `README.md` (actions table, usage, inputs, Composer auth, behaviour, expected project layout).

## Testing and behaviour

- The action runs in the **consumer’s pipeline**; it is not executed inside this repo’s workspace in CI. Local testing requires a consumer-like repo (root `composer.json`, optional `plugins` / paid-plugins layout) and running the script or action from a checkout of this repo.
- When changing script paths or input names, update `action.yml` and all references in README.
- Preserve backward compatibility for inputs and env vars that consumers might already set; prefer adding new optional inputs over changing existing ones.

## References

- **README.md**: Full documentation for consumers (inputs, Composer auth, usage, behaviour).
- Consumer example: workflows that `uses: felipeelia/sitewatch-plugin-upgrades@trunk` (e.g. GitHub-hosted wp-content repos with a “Plugin Updates PR” workflow).
