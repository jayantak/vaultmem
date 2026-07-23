# Hooks

Wire `vaultmem` into your agent harness's lifecycle hooks. Two hook classes are
supported today:

- **SessionStart** — every new session opens with the vault's index shape and
  the session picker. This is the feature that turns vaultmem from a search
  script into ambient agent memory: the agent greets you already knowing
  what's in the vault and what work is open.
- **PostToolUse (Write\|Edit)** — every note write is linted the instant it
  happens (`vaultmem verify`), catching a bad note (dangling wikilink,
  missing frontmatter, a desynced status glyph) at write time instead of at
  the next `doctor` run.

Both hook classes share the same fail-quiet contract described below — see
each section for the exact wiring.

## SessionStart

Two commands belong on the hook:

- `vaultmem status` — the one-line index summary (indexed-note count + MOC list).
- `vaultmem sessions` — the grouped session picker plus the AGENT DIRECTIVE line.

Both are **fail-quiet by contract**: if no vault is mounted (path missing, cloud
drive not synced, no config yet) they print nothing and exit `0`. A hook wrapped
in a `command -v vaultmem >/dev/null &&` guard therefore can **never** break a
session start — on a machine without vaultmem, or with an unmounted vault, the
session opens exactly as it would with no hook at all. Wire it once and forget it.

### Claude Code (`settings.json`)

Add a `SessionStart` block under `"hooks"` in `~/.claude/settings.json` (or a
project `.claude/settings.json`):

```jsonc
{
  "hooks": {
    "SessionStart": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "command -v vaultmem >/dev/null && vaultmem status"
          },
          {
            "type": "command",
            "command": "command -v vaultmem >/dev/null && vaultmem sessions"
          }
        ]
      }
    ]
  }
}
```

To scope it to fresh starts only (not every resume), add a matcher:

```jsonc
{ "matcher": "startup", "hooks": [ /* … */ ] }
```

### Codex (`hooks.json`)

Codex uses the same shape in `~/.codex/hooks.json`, with a `matcher` selecting
the session lifecycle events to fire on. Codex adds a per-hook `statusMessage`
that shows while the command runs:

```json
{
  "SessionStart": [
    {
      "matcher": "startup|resume|clear",
      "hooks": [
        {
          "type": "command",
          "command": "command -v vaultmem >/dev/null && vaultmem sessions",
          "statusMessage": "Loading session picker"
        }
      ]
    }
  ]
}
```

Drop `vaultmem status` in as a second hook entry if you also want the index
summary on Codex — the pattern is identical to the Claude Code block above.

### Customizing the directive line

`vaultmem sessions` ends with an **AGENT DIRECTIVE** — a short instruction telling
the agent how to act on the picker (resume a numbered session, start a new one,
or skip). The built-in default is harness-agnostic:

```
AGENT DIRECTIVE: resume #, new <name>, or skip. …
```

To replace it with your own text (for example, to name the skill that owns your
session flow, or to add a house rule), set `directive_file` in the `[defaults]`
section of your config to a plain-text file:

```toml
[defaults]
directive_file = "~/.config/vaultmem/directive.txt"
```

When `directive_file` points at a readable file, its contents are printed
verbatim as the directive; otherwise the built-in default is used. Keeping the
directive in a file — rather than baked into the tool — lets the SessionStart
integration stay a reusable pattern while the wording adapts to your harness and
skills. See the [Config reference](config.md) for the full `[defaults]` table.

### What the guard buys you

The `command -v vaultmem >/dev/null &&` prefix is doing real work — keep it:

- **Portable config.** The same `settings.json` / `hooks.json` works on a machine
  that has never installed vaultmem; the hook is simply a no-op there.
- **No session-start failures.** Combined with the fail-quiet contract, a broken
  or absent vault degrades to silence, never to an error that blocks the session.

Both properties depend on the guard *and* on `vaultmem status`/`sessions`
exiting `0` when the vault is absent — do not swap in a command that errors on a
missing vault.

## PostToolUse (verify-on-write)

`vaultmem verify <file>` is a single-file, fast lint: dangling wikilinks in
that file, plus the `doctor` schema lints (`NOALIAS`, `GLYPH-DESYNC`,
`GLYPHED-FOLDER`, `NO-UPDATED`, `MISSING-FM`, `EMPTY-BOOKMARK` — see
[SCHEMA.md](../SCHEMA.md)) scoped to just that one note. Wire it to a
**PostToolUse** hook matching `Write|Edit` so a bad note is caught the instant
it's written, instead of waiting for the next `doctor` run.

It is **fail-quiet outside a configured vault**: an agent editing source code
in an ordinary repo triggers a `Write|Edit` PostToolUse hook constantly, so
`verify` exits `0` printing nothing for any path that is not a markdown note
living under a configured vault root (missing file, non-`.md` file, real repo
source, vault not configured — all silent, exit `0`). It returns non-zero
**only** when the given file *is* a vault note and a real lint finding fires.

### Claude Code (`settings.json`)

```jsonc
{
  "hooks": {
    "PostToolUse": [
      {
        "matcher": "Write|Edit",
        "hooks": [
          {
            "type": "command",
            "command": "command -v vaultmem >/dev/null && vaultmem verify \"$CLAUDE_TOOL_INPUT_FILE_PATH\""
          }
        ]
      }
    ]
  }
}
```

Claude Code passes the edited file's path via the `$CLAUDE_TOOL_INPUT_FILE_PATH`
hook variable — see Claude Code's hooks reference for the exact variable name
in your version, since hook payload shapes have changed across releases.

### Codex (`hooks.json`)

Codex's `PostToolUse`-equivalent event and payload shape differ by version;
wire the same command — `vaultmem verify <path-to-edited-file>` — to whatever
post-write hook your Codex version exposes, using its documented way to pass
the edited file's path.

### Why fail-quiet here matters even more than for SessionStart

A `SessionStart` hook fires once per session; a `PostToolUse` hook on
`Write|Edit` fires on **every single file write in every repo**, vault or not.
The `command -v vaultmem >/dev/null &&` guard plus `verify`'s own vault-root
check are both load-bearing: without them, editing a `.ts` file in an
unrelated project would either error (no vaultmem installed) or spuriously
lint a file that was never meant to follow vault schema. Never change `verify`
to do anything but exit `0` silently for a non-vault path.

## Stop hook: `vaultmem nudge`

`vaultmem nudge` is a report-only check for the opposite failure mode from the
SessionStart hooks above: work happened during the session, but the session's
own `Sessions/<thread>/_index.md` was never updated to say so (no `## Work log`
entry, no `updated:` bump). It prints **one** short nudge line when that
happens, and nothing otherwise.

There is no daemon or index behind it — a small stamp file under
`${XDG_CACHE_HOME:-~/.cache}/vaultmem/` (never inside the vault) marks the start
of the window being checked, and `find <vault> -newer <stamp>` does the diffing.
Wire it on **Stop**, same guard pattern as SessionStart:

```jsonc
// ~/.claude/settings.json → "hooks"
{
  "hooks": {
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "command -v vaultmem >/dev/null && vaultmem nudge"
          }
        ]
      }
    ]
  }
}
```

Codex (`~/.codex/hooks.json`) takes the same command under whichever lifecycle
event fires at turn/session end in your version.

`nudge` shares the fail-quiet contract with `status`/`sessions`: a missing or
unconfigured vault, an unwritable cache dir, or (the common case) a first-ever
call with no stamp yet on disk all print nothing and exit `0` — a Stop hook
wired to it can never fail a turn. The first call in a session plants the
stamp; only later calls compare against it and can produce a nudge. If you also
want the stamp anchored at the true start of the session rather than the first
Stop, add the same `vaultmem nudge` command to your SessionStart hooks too —
planting the stamp there is harmless (it is a no-op once the stamp already
exists later in the same run).

## PostCompact: re-anchor after a context compaction

A context compaction throws away everything a SessionStart hook injected
earlier in the conversation — the `vaultmem status` index summary, the
`vaultmem sessions` picker, whatever project/session context the agent had
loaded. The agent resumes with a summarized transcript but no memory of that
injected context, and nothing re-runs it automatically. Wire a `PostCompact`
hook so the agent re-anchors instead of quietly losing vault context for the
rest of the session:

```jsonc
// ~/.claude/settings.json → "hooks"
{
  "hooks": {
    "PostCompact": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "command -v vaultmem >/dev/null && vaultmem status"
          },
          {
            "type": "command",
            "command": "command -v vaultmem >/dev/null && vaultmem project <active-project>"
          }
        ]
      }
    ]
  }
}
```

`vaultmem status` re-prints the index shape and reflex reminder exactly as at
SessionStart — cheap and fail-quiet, safe to fire on every compaction. The
second command is illustrative: swap `<active-project>` for whatever
identifies the thread in flight (a Project name via `vaultmem project <name>`,
or fall back to `vaultmem sessions` to re-show the picker if the agent isn't
tracking a specific project). There is no vaultmem subcommand yet that reads
"the current thread" automatically — that identity lives in the harness, not
in vaultmem, so the hook command has to be seeded with it (a fixed project
name for a single-project setup, or templated by whatever your harness exposes
for the active session). Codex's `hooks.json` does not yet expose a
PostCompact-equivalent event; check your version's lifecycle event list before
porting this block there.
