#!/usr/bin/env bash
# shellcheck disable=SC2016  # backticks in FAIL/status messages are literal display text
# subcommand-lint.sh — drift guard between the skills and the tool.
#
# Every `vaultmem <subcommand>` mentioned in any skills/**/*.md must exist in the
# script's dispatch table. A projected skill referencing a subcommand the tool
# does not have fails here rather than silently shipping.
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

if [ "$fail" -eq 0 ]; then
	printf 'subcommand-lint: all skill subcommand references exist in the dispatch table.\n'
fi
exit "$fail"
