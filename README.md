# sitewatch-plugin-upgrades

**Repository:** [github.com/felipeelia/sitewatch-plugin-upgrades](https://github.com/felipeelia/sitewatch-plugin-upgrades)

Reusable GitHub Actions for SiteWatch projects. This repo hosts multiple actions; each is used by path (e.g. `owner/repo/action-name@ref`). The root action exists only for backwards compatibility and is **deprecated**—prefer the subfolder form.

## Actions in this repo

| Action | Path | Description |
|--------|------|-------------|
| **Plugin Upgrades** | `plugin-upgrades` | Runs `composer update`, builds a PR description, pushes a branch, and opens PRs against your chosen branches (e.g. trunk, staging) in the same repo. *(Root `uses: owner/repo@ref` is deprecated; use `plugin-upgrades`.)* |
| **Vuln plugin update** | `vuln-plugin-update` | *(Planned)* Single- or multi-package vulnerability update and PR creation. |

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
| `separate_vendors_list` | Vendors to list in a separate “Additional packages updated” section (e.g. `phpstan`) | `phpstan` |
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
