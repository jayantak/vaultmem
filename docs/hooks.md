# SessionStart hooks

Wire `vaultmem` into your agent's **SessionStart** event so every new session
opens with the vault's index shape and the session picker. This is the feature
that turns vaultmem from a search script into ambient agent memory: the agent
greets you already knowing what's in the vault and what work is open.

Two commands belong on the hook:

- `vaultmem status` — the one-line index summary (indexed-note count + MOC list).
- `vaultmem sessions` — the grouped session picker plus the AGENT DIRECTIVE line.

Both are **fail-quiet by contract**: if no vault is mounted (path missing, cloud
drive not synced, no config yet) they print nothing and exit `0`. A hook wrapped
in a `command -v vaultmem >/dev/null &&` guard therefore can **never** break a
session start — on a machine without vaultmem, or with an unmounted vault, the
session opens exactly as it would with no hook at all. Wire it once and forget it.

## Claude Code (`settings.json`)

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

## Codex (`hooks.json`)

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

## Customizing the directive line

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

## What the guard buys you

The `command -v vaultmem >/dev/null &&` prefix is doing real work — keep it:

- **Portable config.** The same `settings.json` / `hooks.json` works on a machine
  that has never installed vaultmem; the hook is simply a no-op there.
- **No session-start failures.** Combined with the fail-quiet contract, a broken
  or absent vault degrades to silence, never to an error that blocks the session.

Both properties depend on the guard *and* on `vaultmem status`/`sessions`
exiting `0` when the vault is absent — do not swap in a command that errors on a
missing vault.
