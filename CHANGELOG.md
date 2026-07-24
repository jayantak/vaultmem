# Changelog

All notable changes to this project are documented here.
Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
This project is 0.x — see [Semantic Versioning §4](https://semver.org/spec/v2.0.0.html#spec-item-4)
for what that implies about stability: the CLI surface and config schema can
still change between 0.MINOR releases.

## [0.3.0] - 2026-07-24

### Changed
- **BREAKING (skills):** the bundled skills are restructured from three into
  four, split by the **agent job** rather than by artifact type. `obsidian-vault`
  and `remember-project` are removed; `vault-recall`, `vault-capture`, and
  `vault-curate` join the unchanged `session`. Plugin users get the new names on
  the next marketplace update; symlink users should re-run
  `./install.sh --skills <dir>` and delete the two dangling links. No CLI or
  config change. See [docs/plugin.md § The 0.3.0 rename](docs/plugin.md).

### Added
- `vault-recall` — the recall reflex gets a skill and a trigger of its own:
  "before re-deriving a past decision, root cause, incident, or why-is-it-built-
  this-way, check here first (~60ms, ~700 tokens)". It was previously clause
  `(1b)` inside `obsidian-vault`'s "reference or update your vaults" framing, so
  it only fired once the agent had already thought about the vault. Owns search,
  the Agent Index, graph traversal, and frugal reads.
- `vault-capture` — the write side: note placement, the Agent-Index update as
  definition-of-done, Linking Rules, frontmatter, and the `resolve`/`dangling`
  verification that catches the fabricated-note failure mode. Absorbs
  `remember-project` as § Workflow D: Repo onboarding, drift anchor and both
  `references/` files intact.
- `vault-curate` — new job nothing taught before: what to write next and whether
  the vault is rotting. `doctor`, `doctor --deep`, `dangling --by-target`,
  `frontier`, `groom`.

## [0.2.0] - 2026-07-23

### Added
- `doctor` now lints vault schema alongside Agent-Index drift, with six new
  classes: `NOALIAS`, `GLYPH-DESYNC`, `GLYPHED-FOLDER`, `NO-UPDATED`,
  `MISSING-FM`, `EMPTY-BOOKMARK`. See [SCHEMA.md](SCHEMA.md).
- `doctor --deep` — vault-wide reachability scan reporting `ORPHAN` (no
  inbound wikilinks) and `UNINDEXED` (absent from the Agent Index and every
  MOC). Kept behind a flag so base `doctor` stays fast.
- `INDEX-DRIFT` lint: a Project's `## Sessions` row whose status token
  disagrees with the session's own frontmatter.
- `verify <file>` — single-file lint (dangling wikilinks + schema lints) for
  a `PostToolUse` Write|Edit hook. Fail-quiet outside a vault.
- `nudge` — fail-quiet `Stop`-hook check for vault edits made without
  touching the session note.
- `bookmark <thread>` — print only `## Bookmark` + `## Pinned` from a
  session, the resumable state, without reading the whole file.
- `frontier` — rank notes by `(outbound - inbound) * exp(-days/30)` to
  surface where the knowledge graph is actively growing.
- `dangling --by-target` — aggregate broken links by target with counts,
  ranking the most-wanted missing notes.
- `groom --dry-run` — preview archives and index flips without writing.
- `groom` flags active/parked sessions past `bloat_lines` (default 150,
  configurable) as checkpoint-due.
- `groom` archives `done` Projects and reports stale-active sessions.
- Hook recipes for `PostToolUse`, `Stop`, and `PostCompact` in
  [docs/hooks.md](docs/hooks.md); paste-able agent routing block in the README.

### Changed
- `doctor` exit codes are now distinct and composable: `0` clean, `1` config
  errors, `2` drift/lint findings, `3` both. It previously exited `0` even
  while reporting drift.
- `dangling` is documented in `vaultmem -h` (it was dispatched but absent
  from the usage block).

## [0.1.0] - 2026-07-14
### Added
- Initial public release: search/index over an Obsidian vault, wikilink
  graph commands (`resolve`/`links`/`backlinks`/`neighbors`/`dangling`), the
  Projects→Sessions lifecycle tier, `doctor`/`groom` hygiene, three Claude
  Code agent skills (`obsidian-vault`, `session`, `remember-project`), and a
  Claude Code plugin marketplace manifest.
