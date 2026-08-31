# sitewatch-plugin-upgrades

**Repository:** [github.com/felipeelia/sitewatch-plugin-upgrades](https://github.com/felipeelia/sitewatch-plugin-upgrades)

Reusable GitHub Actions for SiteWatch projects. This repo hosts multiple actions; each is used by path (e.g. `owner/repo/action-name@ref`). The root action exists only for backwards compatibility and is **deprecated**—prefer the subfolder form.

## Actions in this repo

| Action | Path | Description |
|--------|------|-------------|
| **Plugin Upgrades** | `plugin-upgrades` | Runs `composer update`, builds a PR description, pushes a branch, and opens PRs against your chosen branches (e.g. trunk, staging) in the same repo. *(Root `uses: owner/repo@ref` is deprecated; use `plugin-upgrades`.)* |
| **Vuln plugin update** | `vuln-plugin-update` | Update one or more plugins (composer or paid_plugin), push branch(es), and create PRs. Trigger manually from the Actions tab; use comma-separated `update_items` for multiple packages. |

## Plugin Upgrades — Usage

In the repo where you want plugin upgrade PRs (e.g. a wp-content repo with a root `composer.json`), add a workflow that checks out the repo and uses this action. Use the **plugin-upgrades** path (the root form `felipeelia/sitewatch-plugin-upgrades@trunk` is deprecated but still works):

```yaml
name: Plugin Updates PR

on:
  schedule:
    - cron: '0 6 1 * *'
  workflow_dispatch:

jobs:
  plugin-upgrades:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v6

      - name: Plugin upgrades
        uses: felipeelia/sitewatch-plugin-upgrades/plugin-upgrades@trunk
        with:
          prod_branch: trunk
          staging_branch: staging
```

Use `@trunk` for the default branch, or pin to a tag (e.g. `@v1`) for stability.

Push and PR creation use the default `GITHUB_TOKEN`; no extra secrets are required for the same-repo flow.

## Plugin Upgrades — Inputs

| Input | Description | Default |
|-------|-------------|---------|
| `prod_branch` | Branch to open the main upgrade PR against | `trunk` |
| `staging_branch` | Branch to open the staging upgrade PR against | `staging` |
| `additional_branches` | Space-separated list of extra target branches (each gets its own PR) | `''` |
| `wp_plugins_dir` | Path to WordPress plugins directory (for version detection in paid-plugins flow) | `plugins` |
| `paid_plugins_dir` | Directory containing paid plugin zips; leave empty to disable | `''` |
| `separate_vendors_list` | Vendors to list in a separate “Additional packages updated” section | `phpstan php-stubs illuminate phpcsstandards symfony wp-coding-standards` |
| `composer_github_token` | GitHub token for Composer (sets `github-oauth.github.com`). Easiest way to allow private GitHub packages. | `''` |
| `composer_auth` | Full [Composer auth JSON](https://getcomposer.org/doc/03-cli.md#composer-auth) for other hosts (e.g. GitLab). Use when you need more than GitHub. | `''` |
| `php_version` | PHP version for the runner | `8.2` |

## Plugin Upgrades — Composer auth for private packages

**GitHub only (recommended):** Add a repo secret (e.g. `UI_KIT`) with a GitHub token that can read your private packages, then pass it in:

```yaml
- uses: felipeelia/sitewatch-plugin-upgrades/plugin-upgrades@trunk
  with:
    prod_branch: trunk
    staging_branch: staging
    composer_github_token: ${{ secrets.UI_KIT }}
```

The action runs `composer config --global github-oauth.github.com <token>` before `composer update`. No JSON needed.

**Other hosts (GitLab, etc.):** Use the `composer_auth` input with full JSON:

```yaml
- uses: felipeelia/sitewatch-plugin-upgrades/plugin-upgrades@trunk
  with:
    composer_auth: ${{ secrets.COMPOSER_AUTH }}
```

`COMPOSER_AUTH` should be valid JSON, e.g. for GitHub (if you prefer it over `composer_github_token`):

```json
{"github-oauth":{"github.com":"YOUR_GITHUB_TOKEN"}}
```

Or for GitLab:

```json
{"gitlab-token":{"gitlab.example.com":"YOUR_GITLAB_TOKEN"}}
```

You can use both `composer_github_token` and `composer_auth` (e.g. GitHub token + GitLab token).

## Plugin Upgrades — Behaviour

1. **Checkout** is done by your workflow (`actions/checkout@v6`); the action runs in that workspace.
2. The action runs **Composer update** with start/end markers in the log, then parses the output to build a summary.
3. It creates branch `plugin-upgrades/YYYY-MM`, commits all changes, and pushes.
4. It opens one PR per target branch (prod, staging, and any `additional_branches`) with the same generated description (summary + optional paid plugins + raw output in a collapsible section).

Paid-plugins logic (unzip, version diff) runs only if `paid_plugins_dir` is set and the directory exists; otherwise it is skipped.

## Vuln plugin update — Usage

**Designed for manual runs from the Actions tab.** Add a workflow with `workflow_dispatch` and a job that runs your steps (e.g. checkout, any prep), then the action. Other repos can add more steps before calling the action. Because the GitHub UI only provides a single-line text field, use **comma-separated** `mode:package` in `update_items` for multiple packages.

```yaml
name: Vuln Plugin Update

on:
  workflow_dispatch:
    inputs:
      update_mode:
        description: 'Update type (single-package)'
        required: false
        default: 'composer'
        type: choice
        options: [composer, paid_plugin]
      update_package:
        description: 'Single package (e.g. wpackagist-plugin/wordpress-seo) or paid plugin slug'
        required: false
        type: string
      update_items:
        description: 'Multiple: comma-separated mode:package (e.g. composer:wpackagist-plugin/wordpress-seo,paid_plugin:slug)'
        required: false
        type: string
      branch_strategy:
        description: 'Branch strategy'
        default: single_branch
        type: choice
        options: [single_branch, branch_per_env]
      update_kind:
        description: 'PR title/branch kind'
        required: false
        default: vulnerable
        type: choice
        options: [vulnerable, on_demand]

jobs:
  vuln-update:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v6
      # Add your own steps here if needed (e.g. setup, other actions)
      - name: Vuln plugin update
        uses: felipeelia/sitewatch-plugin-upgrades/vuln-plugin-update@trunk
        with:
          update_mode: ${{ inputs.update_mode }}
          update_package: ${{ inputs.update_package }}
          update_items: ${{ inputs.update_items }}
          branch_strategy: ${{ inputs.branch_strategy }}
          update_kind: ${{ inputs.update_kind }}
          prod_branch: production
          staging_branch: preprod
          composer_github_token: ${{ secrets.UI_KIT }}
```

Use either **single-package** (`update_mode` + `update_package`) or **multiple packages** (`update_items`). Composer auth: use `composer_github_token` or `composer_auth`. For paid plugins you need `bin/update-<slug>.sh` in the repo.

## Vuln plugin update — Inputs

| Input | Description | Default |
|-------|-------------|---------|
| `update_mode` | Update type for single-package: `composer` or `paid_plugin` | `composer` |
| `update_package` | Single package (composer name or paid plugin slug) | `''` |
| `update_items` | Multiple packages: **comma-separated** `mode:package` (e.g. `composer:wpackagist-plugin/wordpress-seo,paid_plugin:slug`) | `''` |
| `update_kind` | `vulnerable` (default) or `on_demand`. Changes PR title, commit message, and branch prefix (`vuln-plugins/` vs `on-demand-plugins/`). Required on `workflow_dispatch` for on-demand runs from jira-tickets-automation. | `vulnerable` |
| `branch_strategy` | `single_branch` (one branch, PRs to all targets) or `branch_per_env` (one branch per target) | `single_branch` |
| `source_branch` | For single_branch: branch to create from (empty = prod_branch) | `''` |
| `prod_branch` | Branch to open the main PR against | `trunk` |
| `staging_branch` | Branch to open the staging PR against | `staging` |
| `additional_branches` | Space-separated extra target branches | `''` |
| `composer_dir` | Directory to run Composer in (use `.` when repo root is wp-content) | `'.'` |
| `wp_plugins_dir` | Path to WordPress plugins directory (for version detection) | `plugins` |
| `composer_github_token` | GitHub token for Composer (e.g. `secrets.UI_KIT`) | `''` |
| `composer_auth` | Full Composer auth JSON for other hosts (e.g. GitLab) | `''` |
| `php_version` | PHP version for the runner | `8.2` |
