#!/usr/bin/env bash
# shellcheck disable=SC2016  # a `$PATH` in printf advice text is literal, not an expansion
# install.sh — install vaultmem into ~/.local/bin (or $VAULTMEM_PREFIX/bin).
#
# Curl-installable:
#   curl -fsSL https://raw.githubusercontent.com/jayantak/vaultmem/main/install.sh | bash
# Or from a clone:
#   ./install.sh
#   ./install.sh --skills ~/.claude/skills   # also symlink the bundled skills/
#
# It copies the `vaultmem` script next to this file into the bin dir, checks that
# ripgrep is present, and prints the SessionStart hook snippet. It does not touch
# your shell config or write any vault config — run `vaultmem init --config` for that.
set -euo pipefail

PREFIX="${VAULTMEM_PREFIX:-$HOME/.local}"
BIN="$PREFIX/bin"
SKILLS_DEST=""

while [ $# -gt 0 ]; do
	case "$1" in
	--prefix)
		PREFIX="$2"
		BIN="$PREFIX/bin"
		shift 2
		;;
	--skills)
		SKILLS_DEST="$2"
		shift 2
		;;
	-h | --help)
		sed -n '2,13p' "$0"
		exit 0
		;;
	*)
		printf 'install.sh: unknown arg: %s\n' "$1" >&2
		exit 2
		;;
	esac
done

# Resolve the directory this script lives in, so we find the sibling `vaultmem`.
SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="$SRC_DIR/vaultmem"
[ -f "$SRC" ] || {
	printf 'install.sh: cannot find vaultmem next to this script (%s)\n' "$SRC" >&2
	exit 1
}

mkdir -p "$BIN"
install -m 0755 "$SRC" "$BIN/vaultmem"
printf '✓ installed vaultmem → %s/vaultmem\n' "$BIN"

if ! command -v rg >/dev/null 2>&1; then
	printf '! ripgrep (rg) not found — vaultmem needs it. Install: brew install ripgrep (macOS) / apt install ripgrep (Debian)\n' >&2
fi

case ":$PATH:" in
*":$BIN:"*) ;;
*) printf '! %s is not on your PATH — add it, e.g.  export PATH="%s:$PATH"\n' "$BIN" "$BIN" >&2 ;;
esac

# Optional: symlink the bundled skills into a harness skills dir. The skills/
# tree may not exist yet in early releases — degrade gracefully.
if [ -n "$SKILLS_DEST" ]; then
	if [ -d "$SRC_DIR/skills" ]; then
		mkdir -p "$SKILLS_DEST"
		for d in "$SRC_DIR"/skills/*/; do
			[ -d "$d" ] || continue
			name="$(basename "$d")"
			ln -sfn "$d" "$SKILLS_DEST/$name"
			printf '✓ linked skill %s → %s/%s\n' "$name" "$SKILLS_DEST" "$name"
		done
	else
		printf '! no skills/ directory in this release yet — nothing to link (skipping --skills)\n' >&2
	fi
fi

cat <<'EOF'

Next steps:
  1. vaultmem init --config      # write ~/.config/vaultmem/config.toml
  2. edit the vault path in that file
  3. vaultmem init               # scaffold the vault skeleton
  4. wire the SessionStart hook (Claude Code example):

     // ~/.claude/settings.json → "hooks"
     "SessionStart": [
       { "matcher": "startup",
         "hooks": [
           { "type": "command", "command": "command -v vaultmem >/dev/null && vaultmem status" },
           { "type": "command", "command": "command -v vaultmem >/dev/null && vaultmem sessions" }
         ] }
     ]

  `vaultmem status`/`sessions` are fail-quiet: an unmounted vault exits 0 and
  prints nothing, so the hook can never break a session start.
EOF
