#!/bin/bash

set -eo pipefail

# Branch and list vars; set by GitHub Action or defaults.
PROD_BRANCH="${PROD_BRANCH:-trunk}"
STAGING_BRANCH="${STAGING_BRANCH:-staging}"
ADDITIONAL_BRANCHES="${ADDITIONAL_BRANCHES:-}"

# Vendors to show in a separate list with full vendor/package.
SEPARATE_VENDORS_LIST="${SEPARATE_VENDORS_LIST:-phpstan}"

# Directory containing paid plugin zips; leave empty to disable tracking.
PAID_PLUGINS_DIR="${PAID_PLUGINS_DIR:-}"

# WordPress plugins directory (for reading Version from plugin headers).
WP_PLUGINS_DIR="${WP_PLUGINS_DIR:-plugins}"

# Where to write the PR description (action reads this for gh pr create).
PR_DESCRIPTION_FILE="${PR_DESCRIPTION_FILE:-}"

# Revert composer.lock from https back to git URLs before pushing (for consumers that run
# Setup Composer Auth to allow GitHub Actions to access private GitLab repos).
REVERT_COMPOSER_LOCK_AUTH="${REVERT_COMPOSER_LOCK_AUTH:-true}"

# Capitalize branch name for PR title: develop -> Develop, feature/foo -> Feature/Foo
capitalize_branch() {
	echo "$1" | awk -F'/' '{for(i=1;i<=NF;i++) $i=toupper(substr($i,1,1)) substr($i,2)}1' OFS='/'
}

# Extract package upgrades from composer block (between --- Composer update - start/end ---)
# Outputs lines in the form "vendor/package (version)" for further splitting in build_mr_description.
parse_composer_upgrades() {
	local log_file="$1"
	local block
	block=$(awk '/--- Composer update - start ---/,/--- Composer update - end ---/' "$log_file")
	if [ -z "$block" ]; then
		echo "No Composer update block found."
		return
	fi
	local upgrades
	upgrades=$(echo "$block" | grep -E 'Upgrading.*=>' | sed -n 's/.*Upgrading \([^ (]*\) (\([^)]*\)).*/\1: \2/p' | awk -F': ' '{ print $1 " (" $2 ")" }' | sort -u)
	if [ -z "$upgrades" ]; then
		echo "No package upgrades in this run."
	else
		echo "$upgrades"
	fi
}

# Given lines "vendor/package (version)", output only lines whose vendor is in SEPARATE_VENDORS_LIST.
filter_separate_vendors() {
	local re
	re=$(echo "$SEPARATE_VENDORS_LIST" | sed 's/ /|/g')
	awk -v vendors_re="^($re)/" '$0 ~ vendors_re'
}

# Given lines "vendor/package (version)", output lines whose vendor is NOT in SEPARATE_VENDORS_LIST,
# formatted as "package (version)" (vendor omitted).
format_main_list() {
	local re
	re=$(echo "$SEPARATE_VENDORS_LIST" | sed 's/ /|/g')
	awk -v vendors_re="^($re)/" '$0 !~ vendors_re { sub(/^[^/]+\//, ""); print }'
}

# Capture md5 of all files under a directory to a file (one "hash  path" per line).
capture_paid_plugins_md5() {
	local dir="$1"
	local out="$2"
	if [ ! -d "$dir" ]; then
		touch "$out"
		return
	fi
	find "$dir" -type f -exec md5sum {} \; | sort -k2 > "$out"
}

# Compare two md5 snapshot files; output basenames of files that are new, removed, or changed.
list_paid_plugins_changed() {
	local before="$1"
	local after="$2"
	awk '
		NR==FNR { p = substr($0, 35); b[p] = $1; next }
		{ p = substr($0, 35); a[p] = $1 }
		END {
			for (p in a) if (b[p] == "" || b[p] != a[p]) print p
			for (p in b) if (a[p] == "") print p
		}
	' "$before" "$after" | while IFS= read -r path; do basename "$path"; done | sort -u
}

# Get WordPress plugin version from plugin dir (reads Version: from PHP headers).
get_plugin_version() {
	local dir="$1"
	local slug main_file version
	if [ ! -d "$dir" ]; then
		return
	fi
	slug=$(basename "$dir")
	for main_file in "$dir/index.php" "$dir/$slug.php"; do
		if [ -f "$main_file" ]; then
			version=$(grep -m1 "Version:" "$main_file" 2>/dev/null | sed -n 's/.*Version:[[:space:]]*\([0-9][0-9.]*\).*/\1/p')
			if [ -n "$version" ]; then
				echo "$version"
				return
			fi
		fi
	done
}

# Given newline-separated list of zip basenames, output "slug (old => new)" per line.
paid_plugins_with_versions() {
	local plugins_base="$1"
	local versions_before="$2"
	while IFS= read -r basename_zip; do
		[ -z "$basename_zip" ] && continue
		slug="${basename_zip%.zip}"
		old_version=""
		[ -f "$versions_before" ] && old_version=$(awk -v s="$slug" '$1 == s { print $2; exit }' "$versions_before")
		new_version=$(get_plugin_version "$plugins_base/$slug")
		if [ -n "$old_version" ] && [ -n "$new_version" ]; then
			echo "$slug ($old_version => $new_version)"
		elif [ -n "$new_version" ]; then
			echo "$slug ($new_version)"
		else
			echo "$slug"
		fi
	done
}

# Build PR description: parsed section + optional paid plugins + collapsible Raw output.
build_mr_description() {
	local log_file="$1"
	local out_file="$2"
	local paid_plugins_list="${3:-}"
	local parsed_content
	parsed_content=$(parse_composer_upgrades "$log_file")
	local main_content
	main_content=$(echo "$parsed_content" | format_main_list | sort)
	if [ -n "$paid_plugins_list" ]; then
		main_content=$(printf '%s\n%s' "$main_content" "$paid_plugins_list" | sort -u)
	fi
	local separate_content
	separate_content=$(echo "$parsed_content" | filter_separate_vendors | sort)
	local main_escaped separate_escaped paid_escaped
	main_escaped=$(echo "$main_content" | sed 's/\&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g')
	separate_escaped=$(echo "$separate_content" | sed 's/\&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g')
	paid_escaped=$(echo "$paid_plugins_list" | sed 's/\&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g')
	local raw_escaped
	raw_escaped=$(sed 's/\&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g' "$log_file")
	{
		echo "## Summary"
		echo ""
		echo "<pre>"
		printf '%s' "$main_escaped"
		echo "</pre>"
		if [ -n "$paid_plugins_list" ]; then
			echo ""
			echo "### Paid plugins"
			echo ""
			echo "<pre>"
			printf '%s' "$paid_escaped"
			echo "</pre>"
		fi
		if [ -n "$separate_content" ]; then
			echo ""
			echo "### Additional packages updated (not included in the list above)"
			echo ""
			echo "<pre>"
			printf '%s' "$separate_escaped"
			echo "</pre>"
		fi
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

MONTH_YEAR=$(date +"%Y-%m")
BRANCH_NAME="plugin-upgrades/$MONTH_YEAR"
echo "Creating Plugin Upgrades branch and PR description - $MONTH_YEAR"

TEMPD=$(mktemp -d)
if [ -n "$PAID_PLUGINS_DIR" ] && [ -d "$PAID_PLUGINS_DIR" ]; then
	echo "Unzipping paid plugins (current state) before composer update"
	[ -f "./build/unzip-paid-plugins.sh" ] && ./build/unzip-paid-plugins.sh || true
	echo "Capturing paid-plugins versions before composer update"
	: > "$TEMPD/paid-plugins-versions-before.txt"
	for zip_path in "$PAID_PLUGINS_DIR"/*.zip; do
		[ -f "$zip_path" ] || continue
		slug=$(basename "$zip_path" .zip)
		version=$(get_plugin_version "$WP_PLUGINS_DIR/$slug")
		echo "$slug $version" >> "$TEMPD/paid-plugins-versions-before.txt"
	done
	echo "Capturing paid-plugins state before composer update"
	capture_paid_plugins_md5 "$PAID_PLUGINS_DIR" "$TEMPD/paid-plugins-before.txt"
fi

echo "Running Composer update"
set +e
{
	echo "--- Composer update - start ---"
	composer update
	COMPOSER_EXIT=$?
	echo "--- Composer update - end ---"
	exit "$COMPOSER_EXIT"
} 2>&1 | tee "$TEMPD/update-plugins.log"
LAST_EXIT_CODE=${PIPESTATUS[0]}
set -e
if [ "$LAST_EXIT_CODE" -ne 0 ]; then
	echo "Composer update failed (exit code $LAST_EXIT_CODE)."
	exit 1
fi

PAID_PLUGINS_CHANGED=""
PAID_PLUGINS_LIST=""
if [ -n "$PAID_PLUGINS_DIR" ] && [ -d "$PAID_PLUGINS_DIR" ]; then
	echo "Capturing paid-plugins state after composer update"
	capture_paid_plugins_md5 "$PAID_PLUGINS_DIR" "$TEMPD/paid-plugins-after.txt"
	PAID_PLUGINS_CHANGED=$(list_paid_plugins_changed "$TEMPD/paid-plugins-before.txt" "$TEMPD/paid-plugins-after.txt")
	if [ -n "$PAID_PLUGINS_CHANGED" ]; then
		PAID_PLUGINS_LIST=$(echo "$PAID_PLUGINS_CHANGED" | paid_plugins_with_versions "$WP_PLUGINS_DIR" "$TEMPD/paid-plugins-versions-before.txt" | sort)
	fi
fi

echo "Building PR description"
build_mr_description "$TEMPD/update-plugins.log" "$TEMPD/mr-description.md" "$PAID_PLUGINS_LIST"

if [ -n "$PR_DESCRIPTION_FILE" ]; then
	cp "$TEMPD/mr-description.md" "$PR_DESCRIPTION_FILE"
	echo "PR description written to $PR_DESCRIPTION_FILE"
fi

if [ -n "${PLUGIN_UPGRADES_DEBUG:-}" ]; then
	echo ""
	echo "--------------------------------"
	cat "$TEMPD/mr-description.md"
	echo "--------------------------------"
	rm -rf "$TEMPD"
	exit 255
fi

echo "Setting up Git"
git config user.name "github-actions[bot]"
git config user.email "github-actions[bot]@users.noreply.github.com"

echo "Creating the new branch"
git checkout -B "$BRANCH_NAME"
rm -f auth.json
if [ "$REVERT_COMPOSER_LOCK_AUTH" = "true" ] && [ -f "composer.lock" ]; then
	echo "Reverting composer.lock from https back to git URLs"
	sed -i 's|https://gitlab\.10up\.com/\([^/]*\)/\([^/]*\)\.git|git@gitlab.10up.com:\1/\2.git|g' composer.lock
	sed -i 's|https://gitlab\.10up\.com/\([^/]*\)/\([^/]*\)|git@gitlab.10up.com:\1/\2.git|g' composer.lock
fi
git add -A .
git commit -m "Plugin Upgrades - $MONTH_YEAR" --no-verify

echo "Pushing the new branch"
git push --set-upstream origin "$BRANCH_NAME"

rm -rf "$TEMPD"
echo "Done. PRs will be created by the action."
