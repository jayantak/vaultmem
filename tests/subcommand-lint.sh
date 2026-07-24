#!/usr/bin/env bash
# shellcheck disable=SC2016  # backticks in FAIL/status messages are literal display text
# subcommand-lint.sh — bidirectional drift guard between the skills and the tool.
#
# Forward:  every `vaultmem <subcommand>` mentioned in any skills/**/*.md must
#           exist in the script's dispatch table. A projected skill referencing a
#           subcommand the tool does not have fails here rather than silently
#           shipping.
# Reverse:  every subcommand in the dispatch table must be taught by at least one
#           skill, unless it is in ALLOWED below. The forward check alone was
#           blind to the CLI growing an agent-facing subcommand no skill teaches
#           — which is how `cat` and `bookmark` shipped untaught with CI green.
#
# Passes trivially when there is no skills/ directory yet (early releases ship
# the tool before the skills).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/vaultmem"
SKILLS="$ROOT/skills"

# The set of dispatch-table subcommands: the case labels in the SECOND
# `case "${ARGS[0]:-}" in` block (the first is the vault-guard exemption list).
#
# Built with a read loop, not `mapfile`: macOS ships bash 3.2, which has no
# mapfile. It failed silently here (inside a process substitution, so `set -e`
# never fired) leaving KNOWN empty — which made this lint PASS vacuously on the
# platform it most needed to run on. See docs/development.md § bash 3.2.
KNOWN=()
while IFS= read -r _k; do
	[ -n "$_k" ] || continue
	KNOWN+=("$_k")
done < <(
	awk '/^case "\$\{ARGS\[0\]:-\}" in/{n++} n==2{print}' "$SCRIPT" |
		grep -oE '^[[:space:]]*[a-z][a-z|]*\)' | tr -d ' )' | tr '|' '\n' |
		grep -vE '^$' | sort -u
)
if [ "${#KNOWN[@]}" -eq 0 ]; then
	printf 'subcommand-lint: FAIL — parsed 0 subcommands from the dispatch table.\n' >&2
	exit 1
fi
is_known() {
	local w="$1" k
	for k in "${KNOWN[@]}"; do [ "$k" = "$w" ] && return 0; done
	return 1
}

# Dispatch-table subcommands the skills are NOT expected to teach. Everything
# else must be mentioned by at least one skill. One reason per entry.
#
# Permanent — not agent workflows:
#   init    human one-time vault scaffolding, run before any agent uses the tool
#   nudge   Stop-hook surface, invoked by the harness and never by an agent
#   verify  PostToolUse-hook surface, invoked by the harness and never by an agent
#
# TEMPORARY — remove each entry as the skill PR teaching it lands. These four
# ARE agent-facing and SHOULD be taught; they are exempted only so this lint can
# merge independently of the in-flight skill PRs instead of failing on drift it
# is not itself introducing. Do not add to this group without the same plan.
#   cat       taught by the in-flight sectioned-read skill PR
#   bookmark  taught by the in-flight bookmark-workflow skill PR
#   frontier  taught by the in-flight frontier skill PR
#   doctor    taught by the in-flight hygiene skill PR
ALLOWED="|init|nudge|verify|cat|bookmark|frontier|doctor|"

if [ ! -d "$SKILLS" ]; then
	printf 'subcommand-lint: no skills/ directory — nothing to check (ok).\n'
	printf 'subcommand-lint: dispatch table has %d subcommands.\n' "${#KNOWN[@]}"
	exit 0
fi

# Collect every `vaultmem <word>` reference from the skill markdown. Handles
# inline-code (`vaultmem foo`), fenced blocks, and prose. A leading -v/-n flag
# (`vaultmem -v flo sessions`) is skipped to the first non-flag word.
fail=0
seen=""
while IFS= read -r ref; do
	[ -n "$ref" ] || continue
	case "$seen" in *"|$ref|"*) continue ;; esac
	seen="$seen|$ref|"
	if ! is_known "$ref"; then
		printf 'subcommand-lint: FAIL — skills reference `vaultmem %s`, not in the dispatch table\n' "$ref" >&2
		fail=1
	fi
done < <(
	grep -rhoE 'vaultmem( +-[vn] +[^ ]+)* +[a-z][a-z-]*' "$SKILLS" --include='*.md' 2>/dev/null |
		sed -E 's/^vaultmem( +-[vn] +[^ ]+)*[[:space:]]+//' | sort -u
)

# Reverse: every dispatch-table subcommand must be taught, or allowlisted.
# `seen` was populated above from the same grep the forward check uses, so a
# subcommand counts as taught if any skill mentions `vaultmem <it>`.
#
# Guard against the vacuous pass the forward check learned the hard way: if
# `seen` is empty, the reference grep produced nothing and every non-allowlisted
# subcommand would look untaught — that is a broken lint, not a real failure.
if [ -z "$seen" ]; then
	printf 'subcommand-lint: FAIL — parsed 0 `vaultmem <cmd>` references from %s.\n' "$SKILLS" >&2
	exit 1
fi

checked=0
for cmd in "${KNOWN[@]}"; do
	case "$ALLOWED" in *"|$cmd|"*) continue ;; esac
	checked=$((checked + 1))
	case "$seen" in *"|$cmd|"*) continue ;; esac
	printf 'subcommand-lint: FAIL — `vaultmem %s` is in the dispatch table but no skill teaches it.\n' "$cmd" >&2
	printf '  Fix: document it in a skills/**/*.md workflow, or add it to ALLOWED in %s with a one-line reason.\n' "$0" >&2
	fail=1
done

if [ "$checked" -eq 0 ]; then
	printf 'subcommand-lint: FAIL — reverse check covered 0 subcommands (allowlist swallowed the table?).\n' >&2
	exit 1
fi

if [ "$fail" -eq 0 ]; then
	printf 'subcommand-lint: all skill subcommand references exist in the dispatch table.\n'
	printf 'subcommand-lint: all %d non-allowlisted dispatch subcommands are taught by a skill.\n' "$checked"
fi
exit "$fail"
