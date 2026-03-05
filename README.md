# sitewatch-plugin-upgrades

**Repository:** [github.com/felipeelia/sitewatch-plugin-upgrades](https://github.com/felipeelia/sitewatch-plugin-upgrades)

Reusable GitHub Action that runs `composer update`, builds a PR description from the upgrade output, pushes a branch, and opens PRs against your chosen branches (e.g. trunk, staging) in the **same repo** that runs the workflow. No separate token or target repo configuration.

## Usage

In the repo where you want plugin upgrade PRs (e.g. a wp-content repo with a root `composer.json`), add a workflow that checks out the repo and uses this action:

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
        uses: felipeelia/sitewatch-plugin-upgrades@trunk
        with:
          prod_branch: trunk
          staging_branch: staging
```

Use `@trunk` for the default branch, or pin to a tag (e.g. `@v1`) for stability.

Push and PR creation use the default `GITHUB_TOKEN`; no extra secrets are required for the same-repo flow.

## Inputs

| Input | Description | Default |
|-------|-------------|---------|
| `prod_branch` | Branch to open the main upgrade PR against | `trunk` |
| `staging_branch` | Branch to open the staging upgrade PR against | `staging` |
| `additional_branches` | Space-separated list of extra target branches (each gets its own PR) | `''` |
| `wp_plugins_dir` | Path to WordPress plugins directory (for version detection in paid-plugins flow) | `plugins` |
| `paid_plugins_dir` | Directory containing paid plugin zips; leave empty to disable | `''` |
| `separate_vendors_list` | Vendors to list in a separate “Additional packages updated” section (e.g. `phpstan`) | `phpstan` |
| `composer_auth` | Optional [Composer auth JSON](https://getcomposer.org/doc/03-cli.md#composer-auth) for private packages (e.g. GitHub token). Set via secret. | `''` |
| `php_version` | PHP version for the runner | `8.2` |

## Composer auth (private packages)

If you depend on private packages (e.g. 10up, premium), set the `composer_auth` input from a secret:

```yaml
- uses: felipeelia/sitewatch-plugin-upgrades@trunk
  with:
    prod_branch: trunk
    staging_branch: staging
    composer_auth: ${{ secrets.COMPOSER_AUTH }}
```

`COMPOSER_AUTH` should be valid JSON, e.g. for GitHub:

```json
{"github-oauth":{"github.com":"YOUR_GITHUB_TOKEN"}}
```

Or for GitLab:

```json
{"gitlab-token":{"gitlab.example.com":"YOUR_GITLAB_TOKEN"}}
```

## Behaviour

1. **Checkout** is done by your workflow (`actions/checkout@v6`); the action runs in that workspace.
2. The action runs **Composer update** with start/end markers in the log, then parses the output to build a summary.
3. It creates branch `plugin-upgrades/YYYY-MM`, commits all changes, and pushes.
4. It opens one PR per target branch (prod, staging, and any `additional_branches`) with the same generated description (summary + optional paid plugins + raw output in a collapsible section).

Paid-plugins logic (unzip, version diff) runs only if `paid_plugins_dir` is set and the directory exists; otherwise it is skipped.
