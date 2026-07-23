#!/usr/bin/env bash
# shellcheck disable=SC2016  # backticks in FAIL/status messages are literal display text
# bash32-lint.sh — guard the bash 3.2 floor.
#
# macOS ships bash 3.2 (frozen in 2007; bash 4+ is GPLv3), and vaultmem must run
# there: it is the default shell for the SessionStart hooks and for anyone who
# has not installed a newer bash from Homebrew. A developer on Homebrew bash 5.x
# cannot see these breakages locally — `shellcheck` does not detect them either
# (it has no bash-version target, only a dialect: sh/bash/dash/ksh/busybox).
#
# The real safety net is running the bats suite under /bin/bash (CI does this on
# macos-latest). This lint is the fast, specific complement: it names the
# construct and the line, so the fix is obvious instead of a mystery failure.
#
# Why these constructs, specifically — each has bitten this repo:
#   declare -A / local -A  bash 4.0. FAILS SILENTLY: 3.2 errors on the
#                          declaration, then treats `x[k]=v` as an INDEXED array
#                          with the subscript evaluating to 0, so lookups
#                          collapse to one slot instead of erroring. At file
#                          scope the error also prints on EVERY invocation,
#                          which would break the fail-quiet status/sessions
#                          hook contract.
#   mapfile / readarray    bash 4.0. Inside a process substitution `set -e` does
#                          not fire, so it left an array empty and made
#                          tests/subcommand-lint.sh PASS VACUOUSLY on macOS.
#   ${x^^} / ${x,,}        bash 4.0 case modification. Use tr.
#   |& and &>>             bash 4.0 redirection shorthand. Use 2>&1 | and >>file 2>&1.
#   coproc                 bash 4.0.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# This file is deliberately NOT scanned: it necessarily contains every construct
# it searches for, as pattern strings, so including it makes the lint unable to
# pass. It is plain bash 3.2 itself (verified by CI running it under /bin/bash).
FILES=(vaultmem install.sh tests/subcommand-lint.sh)

fail=0
report() { # $1=label  $2=grep-E pattern  $3=remedy
	local label="$1" pat="$2" remedy="$3" hits
	# Skip comment lines: these constructs are named in prose here and in
	# vaultmem's own explanatory comments.
	hits=$(grep -nE "$pat" "${FILES[@]}" 2>/dev/null | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' || true)
	if [ -n "$hits" ]; then
		printf 'bash32-lint: FAIL — %s (bash 4+, unavailable on macOS bash 3.2)\n' "$label" >&2
		printf '%s\n' "$hits" | sed 's/^/  /' >&2
		printf '  → %s\n' "$remedy" >&2
		fail=1
	fi
}

report 'associative array' \
	'(declare|local|typeset)[[:space:]]+-[A-Za-z]*A' \
	'use a sorted "key<TAB>value" temp file + join/awk, or a newline-delimited set with case matching'
report 'mapfile/readarray' \
	'\b(mapfile|readarray)\b' \
	'use: arr=(); while IFS= read -r x; do arr+=("$x"); done < <(...)'
report 'case-modification expansion' \
	'\$\{[A-Za-z_][A-Za-z0-9_]*(\^\^|,,)' \
	"use: \$(printf '%s' \"\$x\" | tr '[:upper:]' '[:lower:]')"
report 'coproc' '\bcoproc\b' 'restructure with explicit fifos or temp files'
report '|& pipe-with-stderr' '\|&' 'use: 2>&1 |'
report '&>> append-both redirection' '&>>' 'use: >>file 2>&1'

if [ "$fail" -eq 0 ]; then
	printf 'bash32-lint: clean — no bash-4-only constructs in %d files.\n' "${#FILES[@]}"
fi
exit "$fail"
