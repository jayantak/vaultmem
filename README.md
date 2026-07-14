# vaultmem

**Agent memory over an Obsidian vault — bash + ripgrep, no database.**

Your notes are already the memory. `vaultmem` is the fast read/route path over a
plain-markdown [Obsidian](https://obsidian.md) vault: a curated Agent Index, a
wikilink graph, and a session/project tier — all `rg` over `.md` files. Clone it,
read it, it's one bash script. No daemon, no index to rebuild, no vector store to
keep in sync.

<!-- asciinema: replace with an asciinema cast once recorded -->
_(demo: asciinema cast placeholder)_

## Why not a vector DB

Semantic search over a few hundred personal notes is a solution to a problem you
don't have: ripgrep answers in sub-milliseconds, and the highest-signal entry
points are the summaries **you** curate in `Home.md`, not embeddings. A vector
store adds a daemon, an ingestion step, and an index that silently drifts from
the notes. `vaultmem` keeps the notes as the single source of truth and stays
auditable in five minutes. If plain ripgrep ever demonstrably hurts, add an FTS
cache then — not before.

## Install

**curl:**

```bash
curl -fsSL https://raw.githubusercontent.com/jayantak/vaultmem/main/install.sh | bash
```

**clone (it's one file):**

```bash
git clone https://github.com/jayantak/vaultmem
cd vaultmem && ./install.sh
```

Either way you get `vaultmem` in `~/.local/bin`. The one runtime dependency is
[ripgrep](https://github.com/BurntSushi/ripgrep) (`rg`) — `brew install ripgrep`
or `apt install ripgrep`. `install.sh --skills <dir>` also symlinks the bundled
agent skills into a harness skills directory (see [Agent skills](#agent-skills)).

## Quickstart

The five-minute path — install → configure → scaffold → search → wire the hook:

```bash
vaultmem init --config          # writes ~/.config/vaultmem/config.toml
$EDITOR ~/.config/vaultmem/config.toml   # set your vault's path
vaultmem init                   # scaffold Home.md + MOCs/Projects/Sessions/Templates
vaultmem "search term"          # search the vault; curated index hits first
```

Then wire the SessionStart hook so your agent greets you with the index shape and
the session picker (Claude Code example):

```jsonc
// ~/.claude/settings.json → "hooks"
"SessionStart": [
  { "matcher": "startup",
    "hooks": [
      { "type": "command", "command": "command -v vaultmem >/dev/null && vaultmem status" },
      { "type": "command", "command": "command -v vaultmem >/dev/null && vaultmem sessions" }
    ] }
]
```

`status`/`sessions` are **fail-quiet**: if the vault isn't mounted they print
nothing and exit 0, so the hook can never break a session start.

## Concepts

- **Registry** — a restricted-TOML config (`config.toml`) declaring your vaults:
  each vault's path, display label, and optional routing globs. `vaultmem which`
  guesses which vault a directory belongs to from its git remote owner or path;
  everything else consumes the registry so nothing is hardcoded. See
  [Config reference](#config-reference).
- **Agent Index** — the curated hub in `Home.md`, between `AGENT-INDEX` markers:
  one terse row per note (`| [[Note]] | one-line summary |`), grouped in
  sections. It's a triage pointer ("which note?"), the highest-signal thing to
  read first. `index` shows the shape; `index <section>` drills in; `doctor`
  flags rows that have rotted. See [SCHEMA.md](SCHEMA.md).
- **MOCs** — Maps of Content (`MOCs/MOC - <Topic>.md`), one hub note per domain,
  the top of the wikilink graph you fan out from.
- **Projects → Sessions** — two lifecycle tiers. A **Project** (`Projects/<name>.md`,
  `type: project`) is an epic; a **Session** (`Sessions/<thread>/_index.md`) is one
  task under it, with a `status` (`active`/`parked`/`done`) and an `updated:`
  stamp. `projects` / `project <name>` roll them up; `sessions` renders the
  picker.
- **Grooming** — `groom` archives `done` sessions into `Sessions/_archive/` and
  flags `parked` sessions gone cold (untouched past `cold_days`). Hygiene, on
  demand.

## Command reference

**search · index**
```
vaultmem <query>            search all vaults; curated index hits first
vaultmem -v <id> <query>    restrict to one vault
vaultmem -n <N> <query>     cap results (default 20)
vaultmem index [section|all]  browse the Agent Index (shape → section → full dump)
vaultmem mocs               list Maps of Content
```

**graph**
```
vaultmem resolve <name>     resolve a [[wikilink]] to a file path (or DANGLING)
vaultmem links <note>       outbound links, each resolved or flagged dangling
vaultmem backlinks <note>   notes that link TO this one (alias-aware)
vaultmem neighbors <note>   outbound + backlinks together (one-hop view)
vaultmem dangling [note]    broken [[links]] — one note, or the whole vault
```

**router**
```
vaultmem vaults             the registry: id, path, sessions root, home, routing
vaultmem path <id>          bare vault root (for V="$(vaultmem path <id>)")
vaultmem which [dir]        guess which vault a dir belongs to; id on stdout
```

**sessions**
```
vaultmem sessions           the grouped picker (for the SessionStart hook)
vaultmem projects           Project notes + active/total session counts
vaultmem project <name>     one project: repos, linear, MOC, sessions by status
vaultmem status             one-line index summary (fail-quiet)
```

**hygiene · setup**
```
vaultmem groom              archive done sessions; report cold-parked
vaultmem doctor             lint the config + flag drifted index rows
vaultmem init [--vault <id>]  scaffold a compliant vault skeleton
vaultmem init --config      write a starter config.toml
```

## Config reference

`${XDG_CONFIG_HOME:-~/.config}/vaultmem/config.toml`, overridable with
`VAULTMEM_CONFIG=<path>`. It is a **strict subset of TOML** parsed by a small awk
function — **the subset is enforced, and `vaultmem doctor` hard-errors on
anything outside it** so a bad config fails loudly instead of mis-routing
silently (`groom` moves files — silent mis-routing is the failure mode to avoid).

Accepted:

- Headers: `[defaults]` and `[vault.<id>]` only.
- Values: a quoted string `"..."`, a bare `true`/`false`, a bare integer, or a
  bare comma-list token. **Quote every string value.**
- `#` comments.

**Rejected** (all hard-error under `doctor`): arrays (`["a","b"]`), inline tables
(`{...}`), array-of-tables (`[[...]]`), nested tables (`[a.b.c]`), unknown keys,
and unquoted string values.

```toml
[defaults]
vault = "personal"        # fallback vault when routing finds no signal
limit = 20                # default result cap
cold_days = 21            # a parked session untouched this long is grooming-due
directive_file = ""       # optional: path to custom AGENT DIRECTIVE text

[vault.personal]
label = "Personal"
path = "~/Obsidian/Personal"
# sessions = "Sessions"                       # optional, default "Sessions"
# home = "Home.md"                            # optional, default; gates index/doctor/status
# mocs = "MOCs"                               # optional, default "MOCs"
# match_owners = "myorg,my*"                  # git-remote owner globs that route here
# match_paths = "~/src/github.com/myorg/**"   # cwd globs that route here
```

Env overrides: `VAULTMEM_COLD_DAYS` beats `cold_days`. With no config file at
all, the legacy `OBS_FLO`/`OBS_JAY` env vars synthesize a two-vault registry
(kept for backward compatibility; prefer the config).

## Agent skills

vaultmem bundles a set of agent skills that drive the session/memory workflow —
`session` (the resume/park picker), `obsidian-vault` (read/capture), and
`remember-project` (onboard a repo into memory). They reference `vaultmem`
subcommands and [SCHEMA.md](SCHEMA.md) rather than restating the contract, and
CI lints that every subcommand a skill names actually exists in the tool.

> The `skills/` directory ships in a later release. Until then the tool stands
> alone; the sections below describe how they'll install.

**Claude Code** — add the repo as a plugin marketplace:

```
/plugin marketplace add jayantak/vaultmem
```

then enable the plugin; the skills appear namespaced (e.g. `vaultmem:session`).

**Codex / others** — clone and symlink, or use the installer:

```bash
./install.sh --skills ~/.codex/skills
```

The `session` skill assumes the SessionStart hook (see [Quickstart](#quickstart))
is wired — skill install and hook install are one step, not two.

## Design notes

- **Fail-quiet where it counts.** `status`/`sessions` never break a session
  start: an unmounted vault exits 0 silently.
- **Frugality caps.** Results are bounded (`-n`, default 20); the index is
  tiered (shape → section → dump) and rows are width-capped, so output stays a
  triage pointer instead of dumping whole notes into context.
- **Why bash.** The tool's value is that you can read it end to end in one
  sitting and audit exactly what it does to your notes. A compiled rewrite trades
  that away for performance nobody needs at this scale. The one bash pain —
  config parsing — is handled by the restricted TOML subset, zero new deps.

## License

MIT — see [LICENSE](LICENSE).
