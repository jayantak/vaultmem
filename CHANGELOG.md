# Changelog

All notable changes to this project are documented here.
Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
This project is 0.x — see [Semantic Versioning §4](https://semver.org/spec/v2.0.0.html#spec-item-4)
for what that implies about stability: the CLI surface and config schema can
still change between 0.MINOR releases.

## [0.3.0](https://github.com/jayantak/vaultmem/compare/v0.2.0...v0.3.0) (2026-08-17)


### ⚠ BREAKING CHANGES

* **search:** a multi-word query is ANDed rather than matched as one adjacent phrase. Quote the phrase to restore the old behavior.
* the bundled skills go from three to four. `obsidian-vault` and `remember-project` are removed; `vault-recall`, `vault-capture`, and `vault-curate` join the unchanged `session`. Plugin users pick up the new names on the next marketplace update; symlink users should re-run `./install.sh --skills <dir>` and delete the two dangling links. No CLI or config change.

### Features

* **cat:** token-frugal sectioned note read + did-you-mean on misses (R9) ([#13](https://github.com/jayantak/vaultmem/issues/13)) ([70a7eb2](https://github.com/jayantak/vaultmem/commit/70a7eb25058566a8a5b95ae9ef06db0decec996a))
* **doctor:** add a vault-growth watch line (R6) ([#12](https://github.com/jayantak/vaultmem/issues/12)) ([655d8b9](https://github.com/jayantak/vaultmem/commit/655d8b94a4490058bf5b73272359b6e3496c6826))
* **search:** add --exclude for note-body exclusion (R10) ([#16](https://github.com/jayantak/vaultmem/issues/16)) ([00c301d](https://github.com/jayantak/vaultmem/commit/00c301d1711cb49543fc0d7cab4f138f4e1aecf5))
* **search:** add --format cli|json|files for machine-readable output (R2) ([#14](https://github.com/jayantak/vaultmem/issues/14)) ([0929165](https://github.com/jayantak/vaultmem/commit/09291657bbcf48b2fbf79f7611813b3de3bb51a9))
* **search:** AND multi-word queries at file level, quote for phrase ([1910e60](https://github.com/jayantak/vaultmem/commit/1910e60ffd9da5e5c2c7fe991eaa4990515a8f7a))
* split the skills by agent job, giving the recall reflex its own trigger ([#21](https://github.com/jayantak/vaultmem/issues/21)) ([ef729e3](https://github.com/jayantak/vaultmem/commit/ef729e33e649adae8bc6ea771900c333e16d224b))
* **task,worktrees:** add --promote --apply and a worktree index query ([9aa5028](https://github.com/jayantak/vaultmem/commit/9aa50283bfac257458dba1acdeeafdad6ea9e7e7))
* **tasks:** add the backlog tier — planned work before a session ([7078e87](https://github.com/jayantak/vaultmem/commit/7078e87223c2926c0b33499eccc6b8c1f9076fc9))


### Bug Fixes

* **frontier:** resolve links via a per-invocation cache, not per link ([#8](https://github.com/jayantak/vaultmem/issues/8)) ([0755b91](https://github.com/jayantak/vaultmem/commit/0755b91f98b6205d1c1dceae70e0d46fa2e8f4a9))
* **tests:** remove conflict markers left in vaultmem.bats by the R2 squash-merge ([#15](https://github.com/jayantak/vaultmem/issues/15)) ([40f7fae](https://github.com/jayantak/vaultmem/commit/40f7fae8475fdbc8fa59d4555c7424aec2a4cc1b))


### Performance Improvements

* **skills:** cut always-on context in the three vault-* descriptions ([#22](https://github.com/jayantak/vaultmem/issues/22)) ([6063466](https://github.com/jayantak/vaultmem/commit/606346614da409950d0dfe270f48e1245a6383e2))

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
