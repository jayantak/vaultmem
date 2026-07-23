# AGENTS.md — vaultmem

Cold-agent map for this repo. `CLAUDE.md` is a symlink to this file; Codex,
Cursor, Copilot, and Gemini read `AGENTS.md` directly.

## What this is

`vaultmem` is a single POSIX/bash script (`./vaultmem`, ~1200 lines) that
turns a plain-markdown [Obsidian](https://obsidian.md) vault into agent
memory: search (ripgrep-backed), a curated Agent Index, a wikilink graph, and
a Project→Session lifecycle tier. No daemon, no database, no build step — the
script *is* the artifact. This repo also ships:

- `install.sh` — copies `vaultmem` to `~/.local/bin` (or symlinks
  `skills/` into a harness skills dir with `--skills <dir>`).
- `skills/` — three Claude-Code-flavored agent skills (`obsidian-vault`,
  `session`, `remember-project`) that drive the memory workflow on top of the
  CLI.
- `.claude-plugin/` — projects `skills/` into an installable Claude Code
  plugin/marketplace.
- `tests/` — bats unit tests + a skills↔CLI drift lint.

Read the script top-to-bottom before making non-trivial changes — that's the
point of it being one file (see README § Design notes).

## Build / test / validate

No build step (bash script, nothing to compile). Before committing:

```bash
bats tests/vaultmem.bats            # unit tests over the CLI (registry, search, graph, lifecycle)
BASH=/bin/bash bats tests/vaultmem.bats   # …again under macOS system bash 3.2 (see below)
./tests/subcommand-lint.sh          # every `vaultmem <cmd>` referenced in skills/**/*.md must exist in the dispatch table
./tests/bash32-lint.sh              # no bash-4-only constructs (shellcheck cannot see these)
shellcheck vaultmem install.sh tests/subcommand-lint.sh tests/bash32-lint.sh
shfmt --diff vaultmem install.sh tests/subcommand-lint.sh tests/bash32-lint.sh   # must produce no diff
```

This is exactly what CI (`.github/workflows/ci.yml`) runs, split into four jobs:
`lint` (shellcheck + shfmt + the bash-3.2 construct lint), `test` (bats, on
Ubuntu + macOS), `bash32` (bats under macOS `/bin/bash` 3.2), and
`subcommand-lint`. All four must pass before merge.

**Write for bash 3.2, not for the bash on your `$PATH`.** macOS ships bash
3.2.57 as `/bin/bash` (frozen 2007; bash 4+ is GPLv3) and that is what the
`SessionStart` hooks run under, but most contributors have Homebrew bash 5.x —
so `declare -A`/`local -A`, `mapfile`/`readarray`, `${x^^}`, `|&`, `&>>`, and
`coproc` pass locally and break on macOS. Both instances that reached `main`
failed *silently* (a `doctor --deep` that exited 0 finding nothing; a lint that
passed vacuously). `shellcheck` cannot detect this — it targets a dialect, not a
bash version. Full rationale, the banned list, and portable (faster) substitutes:
[docs/development.md](docs/development.md).

Tests never touch a real vault — `tests/vaultmem.bats` builds a throwaway
two-vault registry per test via `VAULTMEM_CONFIG` pointed at a `bats`
tempdir. Follow that pattern (isolated `VAULTMEM_CONFIG` + fixture vaults
under `$BATS_TEST_TMPDIR`) for new tests; never point a test at
`~/.config/vaultmem/config.toml` or a real vault path.

## The CLI subcommand surface

`vaultmem -h` (or the top-of-file comment block, lines ~12–40) is the
authoritative usage summary — read it before adding or renaming a
subcommand. Broad shape: search/index (`<query>`, `index`, `mocs`), the
wikilink graph (`resolve`/`links`/`backlinks`/`neighbors`/`dangling`), the
router (`vaults`/`path`/`which`), the session/project tier
(`sessions`/`projects`/`project`/`groom`/`status`), hygiene (`doctor`), and
setup (`init`).

Subcommands dispatch from the final `case "${ARGS[0]:-}" in` block at the
bottom of the script. **Any subcommand a skill's markdown references by name
must exist there** — `tests/subcommand-lint.sh` enforces this in CI, so a
renamed or removed subcommand that skills still mention fails the build, not
a user's session.

## The config/registry model

Two related but distinct contracts — don't conflate them:

- **Registry** (`~/.config/vaultmem/config.toml`, a restricted TOML subset
  parsed by hand-rolled awk) — *which vaults exist* and how `vaultmem which`
  routes a repo/cwd to one. Full key reference, accepted/rejected TOML shape,
  and the routing algorithm: [docs/config.md](docs/config.md).
- **Schema** ([SCHEMA.md](SCHEMA.md)) — what a compliant vault looks like
  *inside*: folder layout, frontmatter fields the tool reads, the status
  vocabulary (`active`/`parked`/`done`), status-glyph filename convention,
  and the Agent-Index row grammar.

The config parser is deliberately not full TOML — `vaultmem doctor` hard-errors
on anything outside the accepted subset (arrays, nested tables, unquoted
strings, etc.) so a malformed config fails loudly instead of silently
mis-routing. `groom` moves files between folders on disk; a silent mis-route
there is the failure mode the lint exists to prevent. If you touch
`_parse_config`/`_lint_config` in `vaultmem`, keep both docs and the bats
`doctor hard-errors on …` tests in sync with the accepted-subset rules.

## The hooks model

`vaultmem status` and `vaultmem sessions` are designed to run from an agent
harness's `SessionStart` hook (Claude Code `settings.json`, Codex
`hooks.json`) and are **fail-quiet by contract**: an unmounted/unconfigured
vault makes them exit `0` printing nothing, so a hook wired with a
`command -v vaultmem >/dev/null &&` guard can never break a session start.
Full wiring examples for both harnesses, and how to customize the printed
`directive_file` line: [docs/hooks.md](docs/hooks.md). Never change
`cmd_status`/`cmd_sessions` to error on a missing vault — that contract is
load-bearing for every downstream hook config.

## Skills → Claude Code plugin

`skills/` ships three agent skills; `.claude-plugin/{marketplace.json,plugin.json}`
project them into an installable Claude Code plugin (`/plugin marketplace add
jayantak/vaultmem`) where each skill appears namespaced (`vaultmem:session`,
etc.). Non-Claude-Code harnesses skip the manifests and use
`install.sh --skills <dir>` to symlink `skills/<name>/` directly. How
discovery works, what each manifest file is for, and how skill content stays
version-locked to the CLI: [docs/plugin.md](docs/plugin.md).

## Non-obvious gotchas

- **The bash floor is 3.2 (macOS), and violations fail SILENTLY.** bash 3.2
  errors on `local -A`, then parses the next `arr[$path]=1` as an *indexed*
  assignment with an arithmetic subscript — so `doctor --deep` sprayed syntax
  errors per note and still exited 0. `mapfile` inside a process substitution
  doesn't trip `set -e`, which left `subcommand-lint.sh` passing on an empty
  list. Neither is visible on Homebrew bash 5, and neither is detectable by
  `shellcheck`. Run `BASH=/bin/bash bats tests/vaultmem.bats` +
  `./tests/bash32-lint.sh`; see [docs/development.md](docs/development.md).
- **`shellcheck` disables at the top of `vaultmem` are load-bearing, not
  boilerplate** — SC2016 (backticks in the usage/help text are literal, not
  command substitution) and SC2012 (the MOC listing intentionally uses `ls`
  over plain filenames). Don't blanket-remove them to "clean up" a lint pass.
- **`shfmt --diff` is part of CI**, separate from shellcheck — a change that
  passes shellcheck can still fail CI on formatting. Run `shfmt -w vaultmem`
  (or the specific file) before committing if unsure.
- **Status glyphs are presentation, never identity.** A Session's `project:`
  frontmatter field and a Project's session-index `[[wikilink]]` are always
  the *plain* name; the leading emoji (🟢/💤/✅/🔴/🟡) lives only on
  filenames and H1s. Matching logic strips the glyph before comparing — see
  SCHEMA.md § Status-glyph invariants.
- **`updated:` frontmatter, not file mtime, drives staleness math** (cold-parked
  detection, sort order) — file mtime gets rewritten by cloud-drive re-sync
  and would corrupt it. Mtime is only a fallback when `updated:` is
  missing/unparseable.
- **This repo is generated payload for some consumers.** `skills/*/SKILL.md`
  files carry a `<!-- GENERATED from the private dotfiles source repo -->`
  marker — they're synced in from an external private source, not
  hand-authored here. Edit them here for this repo's purposes (they must
  stay accurate and pass `subcommand-lint.sh`), but know a downstream sync
  process — not this repo — is their canonical origin.

## Where deeper truth lives

| Topic | Doc |
|---|---|
| Registry/config keys, TOML subset, routing algorithm | [docs/config.md](docs/config.md) |
| Vault folder layout, frontmatter contract, Agent-Index grammar | [SCHEMA.md](SCHEMA.md) |
| SessionStart hook wiring (Claude Code + Codex), directive customization | [docs/hooks.md](docs/hooks.md) |
| Claude Code plugin packaging, skill discovery, version sync | [docs/plugin.md](docs/plugin.md) |
| Install paths, quickstart, full command reference, design rationale | [README.md](README.md) |
| Skill content itself (workflows, conventions each skill teaches) | `skills/<name>/SKILL.md` |
| bash 3.2 floor, banned constructs, portable substitutes, test conventions | [docs/development.md](docs/development.md) |
