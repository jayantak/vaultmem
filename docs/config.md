# Config reference

The **registry** — the list of vaults vaultmem knows about, where they live, and
how it routes between them. This is the *registry* contract; the per-vault
*content* contract (frontmatter, layout, Agent-Index grammar) lives in
[SCHEMA.md](../SCHEMA.md). One file tells vaultmem which vaults exist; the other
tells it what a compliant vault looks like inside.

## Location

```
${XDG_CONFIG_HOME:-~/.config}/vaultmem/config.toml
```

Override the path with `VAULTMEM_CONFIG=<path>` (used for scripting and test
isolation). Scaffold a starter file with `vaultmem init --config`.

## Format: a restricted subset of TOML

The config is parsed by a small awk function, **not** a full TOML library, so it
accepts only a deliberately narrow subset. The restriction is enforced:
`vaultmem doctor` runs a config lint that **hard-errors** on anything outside the
subset, and the Agent-Index surfaces lint the config before reading it — so a
malformed or ambiguous config **fails loudly** instead of silently mis-routing.
That loudness is the point: `groom` moves files between folders, so a config that
quietly parses wrong is the failure mode to design against.

**Accepted:**

- **Headers** — `[defaults]` and `[vault.<id>]` only, where `<id>` is the short
  name you refer to the vault by (`vaultmem -v <id> …`, `vaultmem path <id>`).
- **Values** — one of:
  - a **quoted string**: `key = "value"` (always quote strings);
  - a bare **boolean**: `key = true` / `key = false`;
  - a bare **integer**: `key = 123`;
  - a bare **comma list** for the routing keys: `key = "a,b*,c"` (a quoted string
    the tool splits on commas).
- **Comments** — `#` to end of line.

**Rejected — every one of these hard-errors under `doctor`:**

- arrays — `key = ["a", "b"]`
- inline tables — `key = { a = 1 }`
- array-of-tables headers — `[[vault]]`
- nested tables — `[vault.foo.bar]`
- multiline strings — `"""…"""`
- unknown keys in a known section
- unquoted string values

Keep it to `[section]` headers, `key = "string" | true | 123`, comma lists, and
`#` comments. Nothing else.

## `[defaults]`

Applies across all vaults.

| Key              | Type    | Default        | Meaning |
|------------------|---------|----------------|---------|
| `vault`          | string  | first vault    | Fallback vault id when routing finds no signal (see `which`). |
| `limit`          | integer | `20`           | Default result cap for search (overridable per-invocation with `-n`). |
| `cold_days`      | integer | `21`           | A `parked` session untouched this many days is flagged cold by `groom`. |
| `directive_file` | string  | *(none)*       | Path to a plain-text file whose contents replace the built-in AGENT DIRECTIVE line printed by `sessions`. |

Environment overrides: `VAULTMEM_COLD_DAYS` beats `cold_days`. If `vault` is
unset, the first vault declared in the file is used as the fallback.

`groom` also flags **stale-active** sessions — `status: active` untouched past
`VAULTMEM_STALE_ACTIVE_DAYS` (default `7`) — as a parallel triage report next to
cold-parked. There is no `stale_active_days` config key yet; the env var is the
only override.

## `[vault.<id>]`

One block per vault. Only `path` is required.

| Key            | Required | Default      | Meaning |
|----------------|----------|--------------|---------|
| `path`         | **yes**  | —            | Vault root on disk. `~` and `$VAR` are expanded. |
| `label`        | no       | the id       | Display name shown in pickers, the index summary, and nudges. |
| `sessions`     | no       | `Sessions`   | Session-tier root folder, relative to `path`. |
| `home`         | no       | `Home.md`    | The Agent-Index note. **Its presence gates the index surfaces** — see below. |
| `mocs`         | no       | `MOCs`       | Maps-of-Content folder, relative to `path`. |
| `match_owners` | no       | *(none)*     | Comma list of git-remote **owner** globs that route a repo to this vault. |
| `match_paths`  | no       | *(none)*     | Comma list of **directory** globs that route a path to this vault. |

`path`, `directive_file`, and `match_paths` all undergo `~`/`$VAR` expansion, so
`path = "~/Obsidian/Personal"` and `match_paths = "~/src/github.com/myorg/**"`
resolve against the running user's home.

## `which` routing

`vaultmem which [dir]` guesses which vault a directory belongs to and prints its
id on stdout. The algorithm walks the vaults **in config order** and returns the
first match:

1. If `dir` is a git repo, take its `origin` remote owner (the `github.com/<owner>`
   segment). The first vault whose `match_owners` glob matches that owner wins.
2. Otherwise, or if no owner matched, the first vault whose `match_paths` glob
   matches `dir` wins.
3. No match → the `[defaults].vault` fallback, with a `low-confidence guess`
   note on **stderr** (stdout still carries a usable id, so scripts keep working).

A single-vault config never exercises routing — everything resolves to that one
vault. Add `match_owners` / `match_paths` only when you keep more than one vault
and want work in different repos to route automatically.

## Per-vault Agent-Index gating

The Agent-Index surfaces — `status`, `index`, `doctor`, `mocs`, and curated
search — read the vault's `home` note (default `Home.md`) with its
`AGENT-INDEX:START` / `:END` markers. A vault gets these surfaces **only when its
`home` note exists**; a vault without one silently skips them (the same
fail-quiet contract the SessionStart hook relies on — see [hooks.md](hooks.md)).

This means a lightweight vault can carry sessions and MOCs without a curated
index: leave `Home.md` out and the session/MOC/graph subcommands still work,
while the index-specific surfaces simply have nothing to show. Run
`vaultmem init` to scaffold a compliant `Home.md` (and the rest of the layout)
when you're ready to curate one.

## Example

```toml
[defaults]
vault = "personal"        # fallback vault when routing finds no signal
limit = 20                # default result cap
cold_days = 21            # a parked session untouched this long is grooming-due
directive_file = ""       # optional: path to custom AGENT DIRECTIVE text

[vault.personal]
label = "Personal"
path = "~/Obsidian/Personal"

[vault.work]
label = "Work"
path = "~/Obsidian/Work"
sessions = "Sessions"                       # optional, default "Sessions"
home = "Home.md"                            # optional, default; gates index/doctor/status
mocs = "MOCs"                               # optional, default "MOCs"
match_owners = "myorg,my*"                  # git-remote owner globs that route here
match_paths = "~/src/github.com/myorg/**"   # cwd globs that route here
```

With no config file at all, the legacy `OBS_FLO` / `OBS_JAY` environment
variables synthesize a two-vault registry (kept for backward compatibility;
prefer the config file).

## See also

- [SCHEMA.md](../SCHEMA.md) — the vault *content* contract: frontmatter fields,
  folder layout, status vocabulary, and the Agent-Index row grammar. `config.md`
  says which vaults exist; SCHEMA.md says what a compliant one looks like inside.
- [hooks.md](hooks.md) — wiring `status` / `sessions` into your agent's
  SessionStart, and pointing `directive_file` at custom picker text.
