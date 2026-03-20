#!/usr/bin/env bash
#
# Vuln/plugin update: run updates, build PR description(s), push branch(es).
# PR creation is done by the GitHub Action (same pattern as plugin-upgrades).
# Supports single package (VULN_UPDATE_MODE + VULN_UPDATE_PACKAGE) or multiple
# (VULN_UPDATE_ITEMS: comma-separated or newline-separated mode:package).
# Requires: one of (VULN_UPDATE_MODE + VULN_UPDATE_PACKAGE) or VULN_UPDATE_ITEMS;
#           optional VULN_UPDATE_BRANCH_STRATEGY (single_branch|branch_per_env).
#           For single_branch: optional VULN_UPDATE_SOURCE_BRANCH (default: PROD_BRANCH).
# Reads from env: PROD_BRANCH, STAGING_BRANCH, ADDITIONAL_BRANCHES,
#                 PR_DESCRIPTION_FILE (single_branch), VULN_PR_MANIFEST + VULN_PR_BODY_DIR (branch_per_env).
# Optional: COMPOSER_DIR (default .), WP_PLUGINS_DIR (default wordpress/wp-content/plugins).
#
set -eo pipefail

PROD_BRANCH="${PROD_BRANCH:-trunk}"
STAGING_BRANCH="${STAGING_BRANCH:-staging}"
ADDITIONAL_BRANCHES="${ADDITIONAL_BRANCHES:-}"
STRATEGY="${VULN_UPDATE_BRANCH_STRATEGY:-single_branch}"
SOURCE_BRANCH="${VULN_UPDATE_SOURCE_BRANCH:-$PROD_BRANCH}"
DATE_SUFFIX=$(date +%Y-%m-%d)
COMPOSER_DIR="${COMPOSER_DIR:-.}"
WP_PLUGINS_DIR="${WP_PLUGINS_DIR:-wordpress/wp-content/plugins}"

# Revert composer.lock from https back to git URLs before pushing (for consumers that run
# Setup Composer Auth to allow GitHub Actions to access private GitLab repos).
REVERT_COMPOSER_LOCK_AUTH="${REVERT_COMPOSER_LOCK_AUTH:-true}"

# --- Build list of (mode, package) items: comma-separated (manual UI) or newline-separated ---
VULN_ITEMS=""
if [ -n "${VULN_UPDATE_ITEMS:-}" ]; then
	# Normalize: replace commas with newlines, then read lines (trim, skip empty)
	normalized=$(echo "$VULN_UPDATE_ITEMS" | tr ',' '\n')
	while IFS= read -r line || [ -n "$line" ]; do
		line=$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
		[ -z "$line" ] && continue
		if ! echo "$line" | grep -qE '^(composer|paid_plugin):'; then
			echo "Error: Each item in VULN_UPDATE_ITEMS must be mode:package (composer or paid_plugin), got: $line"
			exit 1
		fi
		VULN_ITEMS="${VULN_ITEMS}${VULN_ITEMS:+ }${line}"
	done <<EOF
$normalized
EOF
else
	# Single-package from legacy vars
	if [ -z "${VULN_UPDATE_MODE:-}" ]; then
		echo "Error: Set VULN_UPDATE_MODE and VULN_UPDATE_PACKAGE, or VULN_UPDATE_ITEMS (comma-separated mode:package)."
		exit 1
	fi
	if [ "$VULN_UPDATE_MODE" != "composer" ] && [ "$VULN_UPDATE_MODE" != "paid_plugin" ]; then
		echo "Error: VULN_UPDATE_MODE must be 'composer' or 'paid_plugin', got: $VULN_UPDATE_MODE"
		exit 1
	fi
	if [ -z "${VULN_UPDATE_PACKAGE:-}" ]; then
		echo "Error: VULN_UPDATE_PACKAGE must be set (composer package name or paid plugin slug)."
		exit 1
	fi
	VULN_ITEMS="${VULN_UPDATE_MODE}:${VULN_UPDATE_PACKAGE}"
fi

[ -z "$VULN_ITEMS" ] && { echo "Error: No vuln update items (empty VULN_UPDATE_ITEMS or single package)."; exit 1; }

# --- Validate each item and collect package list for messages ---
PACKAGE_LIST=""
for entry in $VULN_ITEMS; do
	mode="${entry%%:*}"
	package="${entry#*:}"
	[ -z "$package" ] && { echo "Error: Missing package in item: $entry"; exit 1; }
	if [ "$mode" = "paid_plugin" ]; then
		UPDATE_SCRIPT="bin/update-${package}.sh"
		if [ ! -f "$UPDATE_SCRIPT" ]; then
			echo "Error: Paid plugin script not found: $UPDATE_SCRIPT"
			exit 1
		fi
	fi
	PACKAGE_LIST="${PACKAGE_LIST}${PACKAGE_LIST:+, }${package}"
done

if [ "$STRATEGY" != "single_branch" ] && [ "$STRATEGY" != "branch_per_env" ]; then
	echo "Error: VULN_UPDATE_BRANCH_STRATEGY must be 'single_branch' or 'branch_per_env', got: $STRATEGY"
	exit 1
fi

echo "=== Vuln plugin update ==="
echo "Packages: $PACKAGE_LIST | Strategy: $STRATEGY | Date suffix: $DATE_SUFFIX"

# --- Helpers ---
get_plugin_version() {
	local dir="$1"
	local slug main_file version
	[ ! -d "$dir" ] && return
	slug=$(basename "$dir")
	for main_file in "$dir/index.php" "$dir/$slug.php"; do
		if [ -f "$main_file" ]; then
			version=$(grep -m1 "Version:" "$main_file" 2>/dev/null | sed -n 's/.*Version:[[:space:]]*\([0-9][0-9.]*\).*/\1/p')
			[ -n "$version" ] && echo "$version" && return
		fi
	done
}

get_composer_installed_version() {
	local pkg="$1"
	(cd "$COMPOSER_DIR" && composer show "$pkg" --installed 2>/dev/null | sed -n 's/.*versions *: *\* *\([^ [:space:]]*\).*/\1/p')
}

build_mr_description() {
	local version_file="$1"
	local log_file="$2"
	local out_file="$3"
	local main_escaped raw_escaped
	main_escaped=$(sed 's/\&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g' "$version_file")
	raw_escaped=$(sed 's/\&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g' "$log_file")
	{
		echo "### Client-facing list of updated plugins"
		echo ""
		echo "<pre>"
		printf '%s' "$main_escaped"
		echo "</pre>"
		echo ""
		echo "<details>"
		echo "<summary>Raw output</summary>"
		echo ""
		echo "<pre>"
		printf '%s' "$raw_escaped"
		echo "</pre>"
		echo ""
		echo "</details>"
	} > "$out_file"
}

run_update() {
	local mode="$1"
	local package="$2"
	if [ "$mode" = "composer" ]; then
		echo "Running: composer update $package in $COMPOSER_DIR"
		pushd "$COMPOSER_DIR"
			COMPOSER_SCAN_NO_FAIL=1
			export COMPOSER_SCAN_NO_FAIL
			if [ -f ../bin/composer-config.sh ]; then
				echo "Running composer-config.sh..."
				../bin/composer-config.sh
			fi
			echo "Running composer update $package..."
			composer update "$package" --no-interaction
			unset COMPOSER_SCAN_NO_FAIL
			export COMPOSER_SCAN_NO_FAIL
		popd
	else
		local update_script="bin/update-${package}.sh"
		echo "Running: $update_script"
		"$update_script"
	fi
}

# Git config (no token in URL; push uses default GITHUB_TOKEN)
echo "Configuring Git..."
git config user.name "github-actions[bot]"
git config user.email "github-actions[bot]@users.noreply.github.com"

if [ "$STRATEGY" = "single_branch" ]; then
	[ -z "$SOURCE_BRANCH" ] && SOURCE_BRANCH="$PROD_BRANCH"
	BRANCH_NAME="vuln-plugins/${DATE_SUFFIX}"
	echo "Strategy: single_branch | Source branch: $SOURCE_BRANCH | New branch: $BRANCH_NAME"
	git fetch origin "$SOURCE_BRANCH"
	git checkout -B "$BRANCH_NAME" "origin/$SOURCE_BRANCH"

	TEMPD=$(mktemp -d)
	LOG_FILE="$TEMPD/update.log"
	VERSION_FILE="$TEMPD/version-list.txt"
	: > "$LOG_FILE"
	: > "$VERSION_FILE"

	for entry in $VULN_ITEMS; do
		mode="${entry%%:*}"
		package="${entry#*:}"
		old_ver=""
		if [ "$mode" = "composer" ]; then
			old_ver=$(get_composer_installed_version "$package" || true)
		else
			old_ver=$(get_plugin_version "$WP_PLUGINS_DIR/$package" || true)
		fi
		run_update "$mode" "$package" 2>&1 | tee -a "$LOG_FILE"
		new_ver=""
		if [ "$mode" = "composer" ]; then
			new_ver=$(get_composer_installed_version "$package" || true)
		else
			new_ver=$(get_plugin_version "$WP_PLUGINS_DIR/$package" || true)
		fi
		if [ -n "$old_ver" ] && [ -n "$new_ver" ]; then
			echo "$package ($old_ver => $new_ver)" >> "$VERSION_FILE"
		elif [ -n "$new_ver" ]; then
			echo "$package ($new_ver)" >> "$VERSION_FILE"
		else
			echo "$package" >> "$VERSION_FILE"
		fi
	done

	echo "Staging changes and committing..."
	rm -f auth.json "$COMPOSER_DIR/auth.json"
	if [ "$REVERT_COMPOSER_LOCK_AUTH" = "true" ] && [ -f "$COMPOSER_DIR/composer.lock" ]; then
		echo "Reverting composer.lock from https back to git URLs"
		sed -i 's|"url": "https://gitlab\.10up\.com/\([^/]*\)/\([^"]*\)\.git"|"url": "git@gitlab.10up.com:\1/\2.git"|g' "$COMPOSER_DIR/composer.lock"
		sed -i 's|"url": "https://gitlab\.10up\.com/\([^/]*\)/\([^"]*\)"|"url": "git@gitlab.10up.com:\1/\2.git"|g' "$COMPOSER_DIR/composer.lock"
	fi
	git add -A .
	git diff --staged --quiet && { rm -rf "$TEMPD"; echo "No changes after update."; exit 1; }
	git commit -m "Vuln plugin update - ${DATE_SUFFIX} (${PACKAGE_LIST})" --no-verify
	echo "Pushing branch $BRANCH_NAME to origin..."
	git push --set-upstream origin "$BRANCH_NAME"

	build_mr_description "$VERSION_FILE" "$LOG_FILE" "$TEMPD/mr-description.md"
	if [ -n "${PR_DESCRIPTION_FILE:-}" ]; then
		cp "$TEMPD/mr-description.md" "$PR_DESCRIPTION_FILE"
		echo "PR description written to $PR_DESCRIPTION_FILE"
	fi
	rm -rf "$TEMPD"
else
	# branch_per_env: one branch per target; write body file per PR and manifest for action
	[ -n "${VULN_PR_MANIFEST:-}" ] && : > "$VULN_PR_MANIFEST"
	PR_INDEX=0
	for TARGET in $PROD_BRANCH $STAGING_BRANCH $ADDITIONAL_BRANCHES; do
		[ -z "$TARGET" ] && continue
		echo "--- Target: $TARGET ---"
		git fetch origin "$TARGET" 2>/dev/null || { echo "Could not fetch $TARGET, skipping."; continue; }

		if [ "$TARGET" = "$PROD_BRANCH" ]; then
			BRANCH_NAME="vuln-plugins/${DATE_SUFFIX}"
		else
			SUFFIX_SLUG=$(echo "$TARGET" | tr '/' '-')
			BRANCH_NAME="vuln-plugins-${SUFFIX_SLUG}/${DATE_SUFFIX}"
		fi
		echo "Creating branch $BRANCH_NAME from origin/$TARGET"
		git checkout -B "$BRANCH_NAME" "origin/$TARGET" 2>/dev/null || { echo "Could not checkout $TARGET, skipping."; continue; }

		TEMPD=$(mktemp -d)
		LOG_FILE="$TEMPD/update.log"
		VERSION_FILE="$TEMPD/version-list.txt"
		: > "$LOG_FILE"
		: > "$VERSION_FILE"

		for entry in $VULN_ITEMS; do
			mode="${entry%%:*}"
			package="${entry#*:}"
			old_ver=""
			if [ "$mode" = "composer" ]; then
				old_ver=$(get_composer_installed_version "$package" || true)
			else
				old_ver=$(get_plugin_version "$WP_PLUGINS_DIR/$package" || true)
			fi
			run_update "$mode" "$package" 2>&1 | tee -a "$LOG_FILE"
			new_ver=""
			if [ "$mode" = "composer" ]; then
				new_ver=$(get_composer_installed_version "$package" || true)
			else
				new_ver=$(get_plugin_version "$WP_PLUGINS_DIR/$package" || true)
			fi
			if [ -n "$old_ver" ] && [ -n "$new_ver" ]; then
				echo "$package ($old_ver => $new_ver)" >> "$VERSION_FILE"
			elif [ -n "$new_ver" ]; then
				echo "$package ($new_ver)" >> "$VERSION_FILE"
			else
				echo "$package" >> "$VERSION_FILE"
			fi
		done

		rm -f auth.json "$COMPOSER_DIR/auth.json"
		if [ "$REVERT_COMPOSER_LOCK_AUTH" = "true" ] && [ -f "$COMPOSER_DIR/composer.lock" ]; then
			echo "Reverting composer.lock from https back to git URLs"
			sed -i 's|"url": "https://gitlab\.10up\.com/\([^/]*\)/\([^"]*\)\.git"|"url": "git@gitlab.10up.com:\1/\2.git"|g' "$COMPOSER_DIR/composer.lock"
			sed -i 's|"url": "https://gitlab\.10up\.com/\([^/]*\)/\([^"]*\)"|"url": "git@gitlab.10up.com:\1/\2.git"|g' "$COMPOSER_DIR/composer.lock"
		fi
		git add -A .
		if git diff --staged --quiet; then
			rm -rf "$TEMPD"
			echo "No changes after update for $TARGET, skipping."
			continue
		fi
		echo "Committing and pushing $BRANCH_NAME..."
		git commit -m "Vuln plugin update - ${DATE_SUFFIX} (${PACKAGE_LIST})" --no-verify
		git push --set-upstream origin "$BRANCH_NAME"

		build_mr_description "$VERSION_FILE" "$LOG_FILE" "$TEMPD/mr-description.md"
		SUFFIX_LABEL=$(echo "$TARGET" | sed 's/\// /g')
		[ "$TARGET" = "$PROD_BRANCH" ] && MR_TITLE="Vuln plugin update - ${DATE_SUFFIX}" || MR_TITLE="Vuln plugin update - ${DATE_SUFFIX} (${SUFFIX_LABEL})"

		if [ -n "${VULN_PR_MANIFEST:-}" ] && [ -n "${VULN_PR_BODY_DIR:-}" ]; then
			PR_INDEX=$((PR_INDEX + 1))
			BODY_FILE="${VULN_PR_BODY_DIR}/vuln-pr-${PR_INDEX}.md"
			cp "$TEMPD/mr-description.md" "$BODY_FILE"
			printf '%s\t%s\t%s\t%s\n' "$BRANCH_NAME" "$TARGET" "$MR_TITLE" "$BODY_FILE" >> "$VULN_PR_MANIFEST"
		fi
		rm -rf "$TEMPD"
	done
fi

echo "Done."
