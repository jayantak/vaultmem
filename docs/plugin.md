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
      "version": "0.3.0",
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
  vault-recall/SKILL.md         → vaultmem:vault-recall
  session/SKILL.md              → vaultmem:session
  vault-capture/SKILL.md        → vaultmem:vault-capture
  vault-curate/SKILL.md         → vaultmem:vault-curate
```

A skill's `references/` subdirectory (e.g. `skills/session/references/distill.md`,
`skills/vault-capture/references/question-tree.md`) travels with it — the plugin
ships the whole `skills/<name>/` tree, not just the `SKILL.md` file.

Because discovery is convention, a **renamed** skill directory is a breaking
change for anyone who symlinked the old one: the new name is picked up
automatically, but the stale symlink keeps pointing at a directory that no
longer exists. See § The 0.3.0 rename below.

## The 0.3.0 rename (breaking)

0.3.0 split the skills by **agent job** rather than by artifact type, because a
skill only fires when its description matches what the agent is about to do:

| Removed | Replaced by |
|---|---|
| `obsidian-vault` | `vault-recall` (read/search/traverse) + `vault-capture` (write) + `vault-curate` (health & gaps) |
| `remember-project` | `vault-capture` § Workflow D: Repo onboarding (+ its `references/`) |

The motivating case: the single most valuable behavior in this system is the
**recall reflex** — check the vault before re-deriving a past decision, since a
miss costs ~60ms and ~700 tokens. It used to be clause `(1b)` inside
`obsidian-vault`'s description, whose dominant framing was "reference or update
your Obsidian vaults." That only fires once the agent has *already* decided to
think about the vault, which is backwards. `vault-recall`'s description now
leads with the reflex.

Upgrading: Claude Code plugin users get the new skills on the next marketplace
update. Symlink users should re-run `./install.sh --skills <dir>` and delete the
now-dangling `obsidian-vault` and `remember-project` links.

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

A skill's prose can drift from the tool it documents — in both directions. CI
guards both with [tests/subcommand-lint.sh](../tests/subcommand-lint.sh):

- **Forward** — every `` `vaultmem <word>` `` a skill mentions must exist in the
  script's dispatch table, so a renamed or removed subcommand fails the build
  instead of a user's session.
- **Reverse** — every subcommand in the dispatch table must be taught by at
  least one skill (barring the human/harness surfaces in its `ALLOWED` list), so
  the CLI can't grow an agent-facing command no skill mentions.

Run it locally with `./tests/subcommand-lint.sh`.

## This repo is canonical for skill content

`skills/` is the source of truth. Consumers that vendor these skills — notably
a dotfiles/chezmoi tree that deploys them to `~/.claude/skills/` — are
**downstream**: they sync *from* here and never the other way. Each skill file
carries a one-line `<!-- CANONICAL SOURCE: … -->` marker saying so.

This replaces an earlier one-way model that pointed the other direction. It
failed the way unenforced one-way syncs do: both copies were edited, neither
became a superset, and reconciling them took a hand-run three-way merge. If you
have a vendored copy, re-sync it from this repo rather than editing it in place:

```bash
# from a dotfiles/chezmoi checkout, with $VAULTMEM pointing at a clone of this repo
for s in vault-recall session vault-capture vault-curate; do
  rsync -a --delete "$VAULTMEM/skills/$s/" "home/agents-source/skills/$s/"
done
```

Then review the diff and commit it there. Content edits belong in this repo's
`skills/`; the only changes that legitimately originate downstream are ones that
would be wrong to ship publicly (e.g. private vault names), and those are better
handled by keeping the public copy generic than by forking it again.

## Bumping the plugin version

`plugin.json` and `marketplace.json` both carry a `version` field
(currently `0.3.0`); keep them in lockstep when you cut a release — the
marketplace entry's `version` is what `/plugin marketplace add` surfaces to
installers.

## See also

- [README.md § Agent skills](../README.md#agent-skills) — the four bundled
  skills, what each does, and the two install paths.
- [SCHEMA.md](../SCHEMA.md) — the vault contract the skills write to.
- [docs/config.md](config.md) — the registry the skills route through
  (`vaultmem vaults` / `vaultmem which`).
