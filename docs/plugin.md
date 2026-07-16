# Claude Code plugin

How `skills/` becomes an installable Claude Code plugin, and what each file in
`.claude-plugin/` does. This is packaging documentation — the skills'
*content* (workflows, conventions) is documented in each `skills/<name>/SKILL.md`;
this page covers how they're projected and distributed.

## The two manifest files

Claude Code plugins are discovered through a **marketplace** — a repo with a
`.claude-plugin/marketplace.json` listing one or more installable plugins. This
repo is both the marketplace and the (single) plugin it lists.

```
.claude-plugin/
  marketplace.json   # the marketplace: lists this repo's one plugin
  plugin.json         # the plugin manifest: metadata for that one plugin
```

**`marketplace.json`** — read by `/plugin marketplace add jayantak/vaultmem`.
Its `plugins[]` array has one entry, `source: "./"`, pointing back at this
repo root:

```json
{
  "name": "vaultmem",
  "owner": { "name": "jayantak", "url": "https://github.com/jayantak" },
  "plugins": [
    {
      "name": "vaultmem",
      "source": "./",
      "description": "...",
      "version": "0.1.0",
      "license": "MIT",
      "keywords": ["obsidian", "agent-memory", "skills"]
    }
  ]
}
```

**`plugin.json`** — the plugin manifest at the repo root. Claude Code reads
this once the plugin above is enabled; there is no explicit skill list inside
it — every directory under `skills/` is projected automatically (see below).

## Skill discovery: convention, not configuration

Claude Code's plugin loader walks `skills/*/SKILL.md` and registers each
directory as one skill, namespaced `<plugin-name>:<skill-dir-name>`. Nothing in
either manifest enumerates them — adding a skill is just adding a directory:

```
skills/
  obsidian-vault/SKILL.md       → vaultmem:obsidian-vault
  session/SKILL.md              → vaultmem:session
  remember-project/SKILL.md     → vaultmem:remember-project
```

A skill's `references/` subdirectory (e.g. `skills/session/references/distill.md`)
travels with it — the plugin ships the whole `skills/<name>/` tree, not just
the `SKILL.md` file.

## Install paths

**Claude Code** — add the marketplace, then enable the plugin (skills appear
namespaced, e.g. `vaultmem:session`):

```
/plugin marketplace add jayantak/vaultmem
```

**Any other harness (Codex, etc.)** — no marketplace concept, so skip the
manifests entirely and symlink `skills/<name>/` straight into the harness's
own skills directory. `install.sh --skills <dir>` automates this — see
[install.sh](../install.sh) and the README's
[Agent skills](../README.md#agent-skills) section.

## Keeping skills and the CLI in sync

A skill's prose can drift from the tool it documents — it might reference a
`vaultmem` subcommand that got renamed or removed. CI guards against this:
[tests/subcommand-lint.sh](../tests/subcommand-lint.sh) greps every
`skills/**/*.md` for `` `vaultmem <word>` `` references and fails the build if
any subcommand isn't in the script's dispatch table. Run it locally with
`./tests/subcommand-lint.sh`.

## Bumping the plugin version

`plugin.json` and `marketplace.json` both carry a `version` field
(currently `0.1.0`); keep them in lockstep when you cut a release — the
marketplace entry's `version` is what `/plugin marketplace add` surfaces to
installers.

## See also

- [README.md § Agent skills](../README.md#agent-skills) — the three bundled
  skills, what each does, and the two install paths.
- [SCHEMA.md](../SCHEMA.md) — the vault contract the skills write to.
- [docs/config.md](config.md) — the registry the skills route through
  (`vaultmem vaults` / `vaultmem which`).
