---
name: session
description: Always-active cross-session working memory. Auto-activates every conversation to offer resuming or starting a session. Also triggers on "start a session", "resume", "park this", "save this", "wrapping up", or multi-session/multi-repo work. Routes work to the correct Obsidian vault, groups sessions under a parent Project (epic), and distills durable insights up into the Project note and MOCs at stopping points.
allowed-tools: Bash(vaultmem *), Bash(git *), Bash(stat *), Bash(find *), Read, Write, Edit, Glob, Grep
---

<!-- GENERATED from the private dotfiles source repo — edit there, not here. -->

# session — cross-session working memory

The hot layer above the durable Obsidian vaults. Sessions are per-thread
worklogs that survive `/clear`. The conversation is disposable; the session
file is the state. Pairs with `vaultmem` (search/registry/router) and
`obsidian-vault` (durable capture).

The vault layout, frontmatter fields, status vocabulary, and glyph convention
this skill writes are the normative contract in `SCHEMA.md` (run `vaultmem
vaults` for the live registry). The templates below are the operational shapes;
`SCHEMA.md` is the reference when they disagree.

## Always-on activation

The `SessionStart` hook prints a picker line (`vaultmem sessions`) ending
in an AGENT DIRECTIVE — the trailing prompt that tells the agent what to do
with the picker. Its wording is configurable (the registry's `directive_file`);
the default asks the agent to route session handling through this skill. That
directive is binding: invoke this skill FIRST, every
conversation, before any other skill, tool call, or reply. Memory lookups
(`obsidian-vault`, `vaultmem`) do NOT substitute — even when they read the
same session file, route through this skill first, then continue. Be concise;
never block the user's actual task. If the user skips, do NOT re-ask this
conversation.

**Trivial one-shot exception:** if the first user message is a quick question
or a single read-only lookup answerable in one reply, skip this skill silently
and just answer. The moment the thread turns into real work (edits, a task, a
second substantive turn), invoke the skill then. Never announce the skip.

## Vault routing (never hardcode a vault)

Always resolve the vault through the router:

- Guess: `vaultmem which` (prints the routed vault id).
- Confirm with one line: "New session in the **<vault>** vault — ok? (or say the other)".
- Registry facts (paths, sessions root, default MOC): `vaultmem vaults`.

Resolve `<vault_path>` with `vaultmem path <vault>` (bare path on
stdout — use it directly in scripts as `V="$(vaultmem path <vault>)"`;
`vaultmem vaults` still prints the full registry).

## A session is one task, not one project

A session = **one focused unit of work** (a feature, a bug, an investigation).
The tier *above* a session is a **Project** (`Projects/<name>.md`) — that is
where cross-session state accumulates. When the unit of work closes, **park the
session and open a fresh one under the same Project**; do not keep one session
open as a stand-in for the whole project (that is what makes `_index.md`
balloon). Tiers: **MOC** (domain map) → **Project** (epic, owns repos +
cross-session state) → **Session** (one thread).

List projects with `vaultmem projects`; see one with
`vaultmem project <name>` (its repos, linear pointer, MOC, and sessions
by status).

## Create a session

1. Route + confirm vault (above).
2. **Attach to a Project.** Resolve the parent epic:
   - Run `vaultmem which` for the vault, then `vaultmem projects`
     to see candidates. If the cwd is a repo, prefer the Project whose `repos:`
     lists it.
   - If exactly one fits, use it. If ambiguous or none, ask one line: "Which
     project does this belong to — `<a>` / `<b>` / new / none?".
   - If a new Project is needed, create `Projects/🟢 <name>.md` from the Project
     shape (below) with `type: project`, `status: active`, `repos:`, and
     `aliases: ["<name>"]` (glyph on filename + H1; see Status glyphs below).
3. Pick a short kebab `<thread>` from the task.
4. Write `<vault_path>/Sessions/<thread>/_index.md` from the template, stamping
   `project:`, `aliases: [<thread>]` (so the Project's back-link resolves), +
   inheriting `repos:` from the Project, and auto-linking MOCs/repos/people
   inferred from the opening context.
5. **Register the session on the Project.** Append a line to the Project note's
   `## Sessions` index: `- [[<thread>]] — <one-line> (status: active)` (+ the
   tracker issue id if the project has one, e.g. `(PROJ-1234, active)`). This `[[<thread>]]` only
   resolves because step 4 gave the session an `aliases: [<thread>]` entry.

### `_index.md` template

```markdown
---
thread: <thread>
project: <project-or-blank>
vault: <vault-id>
status: active
aliases: [<thread>]   # REQUIRED — so [[<thread>]] back-links resolve (the file is _index.md, basename ≠ thread)
updated: <YYYY-MM-DD HH:MM>
---
# 🟢 <thread>
**Goal:** <one line>   **Project:** [[<project>]]   **MOCs:** [[<moc>]]   **People:** [[<person>]]
**Repos:** [[<repo>]] (branch <branch>)   **Related:** [[<prior-session>]]

## Bookmark
Last: <what just happened> · Next: <next action> · Open: <unresolved>

## Pinned

## Work log

## Decisions

## Git state
| Repo | Branch / worktree | PR | State |
|---|---|---|---|
```

**Parent Project.** `project:` is the session's parent epic — a `Projects/<name>.md`
note. The picker groups sessions by it, and distill promotes durable bits up to
it. Leave it blank only for genuinely one-off work with no home. `repos:` default-
inherit from the Project note; restate them in the header (override only if this
session touches a different repo).

**The spine is fixed; topical sections are free-form.** `Bookmark`, `Pinned`,
`Work log`, `Decisions`, `Git state` are the required skeleton. Add your own
`## <topic>` working sections as the task needs them (an analysis in progress, a
decomposed plan, a verdict) — real sessions grow these, and distill collapses
them. Don't force everything into the work log.

**`## Pinned` = load-bearing constants that must survive distill.** The handful
of facts you'd be annoyed to re-derive: the stage/env gotcha, the one binding
constraint, the non-obvious command, the canonical file to edit, the worktree
layout. Keep it short (≤6 lines); it is re-read first on resume. Distill never
strips it — correct it in place when a constant changes. (Leave the heading empty
until you have a constant worth pinning.)

**Link targets must resolve.** The `[[<moc>]]` / `[[<repo>]]` / `[[<person>]]`
placeholders are not free text — a wikilink works only if a note's exact
basename or alias matches. Link MOCs by filename `[[MOC - <Topic>]]` (or a
declared alias like `[[Payments]]`); for a repo/person, link only if a real note
exists (`vaultmem mocs` / `index` to check), else use plain text. Never
wikilink repo artifacts (ADR IDs, file paths, PR numbers). Full rules:
`obsidian-vault` § Linking Rules.

### The Project note (`Projects/<name>.md`)

The long-lived epic. Frontmatter:

```yaml
---
type: project
status: active            # active | parked | done
vault: <vault-id>
repos: [<repo>]           # sessions inherit this
linear: <url>             # optional, if the project tracks tickets (read for context; never a worklog)
moc: "[[MOC - <Topic>]]"  # optional — the domain map above this project
updated: <YYYY-MM-DD>
---
```

Body spine: `## Sessions` (the index, grouped by status) · `## Pinned`
(cross-session load-bearing constants) · `## Decisions` (durable cross-session
decisions) · free-form topical sections. Keep it lean the same way `_index.md`
is — distill (below) is what keeps it that way.

### Status glyphs (sidebar self-sorts by state)

Every Project and Session carries a status glyph so the Obsidian file-tree
sidebar shows state at a glance. The glyph maps 1:1 to the `status:` field:

| status | glyph |
|---|---|
| active | 🟢 |
| parked | 💤 |
| done / shipped | ✅ |

- **Session** (`_index.md`): glyph goes on the **H1 only** (`# 🟢 <thread>`).
  NEVER glyph the session *folder* name — `vaultmem` keys sessions by
  folder basename == the `thread:` field, so a glyphed folder desyncs them and
  breaks the picker/groom. Sessions churn fast and their status shows in the
  picker anyway, so the H1 glyph is enough.
- **Project** (`Projects/<name>.md`): glyph goes on **both the filename and the
  H1** (`🟢 <name>.md` / `# 🟢 <name>`) — the filename is what the sidebar
  sorts. Renaming a flat project file is safe as long as you first add the
  plain name as a frontmatter `aliases:` entry (`aliases: ["<name>"]`) so every
  existing `[[<name>]]` link keeps resolving. `vaultmem` strips the
  leading glyph when matching a project to its sessions, so sessions keep the
  **plain** `project:` name — never write the glyph into a session's `project:`.
- **Keep it in sync on every transition.** When a status flips (active→parked at
  park, →done at retire), update the glyph in the same write: the H1 for a
  session; the H1 **and the filename** for a project (re-`mv` + keep the alias).
  A stale glyph is a lie the sidebar tells — treat it like a stale `## Bookmark`.
- Non-status notes (references, reviews, `2026 Review`) take no status glyph.

## Indexed mode (auto-persist, no prompts)

Once a session is active, after every few tool calls (or whenever you produce
durable content — decisions, findings, plans):

**First edit of the conversation: Read `_index.md` before editing it** (a
section read via offset/limit satisfies this). The Edit tool rejects writes
to never-read files — this is the top recorded tool error in past sessions.
The same applies to the Project note and `MEMORY.md`.

1. Append a timestamped bullet to `## Work log`. Lead it with a status marker
   when it helps scanning — **DONE** / **BLOCKED** / **DECISION** / **NEXT**.
2. Rewrite `## Bookmark` (Last / Next / Open) — always current, never stale.
3. If git state moved (branch, PR, worktree, merge/push), refresh `## Git state`
   **in the same write**. The work log is the source of truth for what happened;
   the table is just the at-a-glance index — never let it contradict the log.
4. Add or correct a `## Pinned` constant if this turn surfaced one (a gotcha,
   a binding decision, the canonical command/path).
5. Keep header wikilinks current (`[[MOC]]`, `[[repo]]`, `[[person]]`,
   `[[prior-session]]`); bump `updated:`.

Never keep durable results only in conversation memory. The write is atomic:
content + Bookmark (+ Git state if it moved), same turn. Corrections edit the
existing section in place rather than appending.

**Re-anchor periodically.** On a long thread, every ~5–6 substantive turns
re-read your own `## Bookmark` + `## Pinned` before deciding the next move — it
keeps you on the task instead of drifting with the conversation, and it surfaces
when the file has bloated enough to checkpoint (below).

## Resume

Read ONLY the `## Bookmark` + `## Pinned` blocks with Read offset/limit — not the
whole file. Those two are the resumable state (what just happened / what's next /
the load-bearing constants). Read further sections only if the next action needs
them. The picker's number/name selects the thread; resolve its `_index.md` path.

## Checkpoint (distill in place, keep going)

Checkpoint is the pressure-release valve that keeps `_index.md` lean **without
needing a stopping point**. Trigger it on the FIRST of these — don't wait for the
user to ask:

- the user says "checkpoint" / "distill but keep going"; OR
- `_index.md` drifts past **~150 lines** (the work log is dense — it bloats fast); OR
- the conversation has run long / context is filling AND you've produced durable
  content (a decision, a finished analysis, a shipped change) since the last
  distill — checkpoint at the next turn boundary rather than riding context to the
  edge. Catching it early beats an emergency compaction that loses the trail.

Then load [references/distill.md](references/distill.md) and run the
**checkpoint** flow: promote durable bits to the vault, collapse the promoted
work-log entries to `→ promoted to [[note]]` pointers, leave `## Pinned` intact,
and keep `status: active`. No `_meta.md` event, no clear — the conversation
continues. It is the lighter alternative to park when there's no stopping point
yet. A one-line confirm is enough; don't interrupt the user's flow to ask
permission for an in-place checkpoint.

## Park / end + distill

When the user says "park", "wrapping up", "let's clear", OR you detect a natural
stopping point (task list drained AND a coherent unit closed AND context
growing), load [references/distill.md](references/distill.md) and run the **park**
flow (checkpoint + `_meta.md` event + clear-safe). Offer: "Natural stopping point
— distill durable bits into the vault and clear?"

## Lifecycle & grooming

A session moves `active → parked → done`, then is **archived** — `archived` is a
*location*, not a status: archived sessions live under `Sessions/_archive/<thread>/`
and drop out of every listing surface (picker, `projects`, `project`). Wikilinks
resolve by basename, so `[[<thread>]]` keeps working after the move. The picker
shows **active + parked only** (resumable work); `done` is hidden, awaiting groom.
On each transition, update the session H1 glyph (🟢→💤→✅) in the same write —
and when a **Project's own** status changes, re-`mv` its file to the new glyph
(💤 when parked, ✅ when shipped) and fix its H1, keeping the plain-name alias.

The SessionStart picker appends a `⚠ … run vaultmem groom` nudge when a
vault has `done` sessions (ready to archive), `parked` sessions untouched past
`OBSIDIAN_SESSION_COLD_DAYS` (default 21), or `active` sessions untouched past
`VAULTMEM_STALE_ACTIVE_DAYS` (default 7). `vaultmem status` surfaces the same
nudge in short form. When you see it:

- **`vaultmem groom`** mechanically moves every `done` session into
  `_archive/` and flips its parent Project's `## Sessions` line to `archived`.
  Safe to run anytime (done was already distilled at park). Scope with `-v <vault>`.
  It also archives every `done` **Project** into `Projects/_archive/` — unless a
  session outside `_archive/` still points at it, in which case `groom` prints a
  warning naming the blocking session(s) instead of moving it. Clear those first
  (archive or reassign the session) and re-run `groom`.
- It also **lists cold-parked sessions for triage** — it never auto-retires them.
  For each, drive the decision with the user: **resume** (open it, status back to
  `active`), or **retire**. To retire: confirm it was distilled at its last park
  (it has a `_meta` park event / `→ promoted` pointers — cold means untouched
  since park, so normally yes); if not, run the distill loop
  ([references/distill.md](references/distill.md)) first; then set `status: done`
  so the next `groom` archives it.
- It also **lists stale-active sessions for triage** — an `active` session that
  has gone untouched this long likely stalled. Drive the same decision with the
  user: **park** it (if paused but not abandoned), or if the bookmark shows the
  work actually finished, set `status: done` so the next `groom` archives it.

## Frugality rule

Never read a full file when a section will do. The `_index.md` IS the state;
keep it ~100–150 lines — when it grows past that, **checkpoint** (see above) to
promote and collapse rather than letting it bloat. Search across everything with
`vaultmem <query>`; follow `[[links]]` between notes with
`vaultmem links` / `backlinks` (see `obsidian-vault` § Researching by
following wikilinks) instead of reading whole folders.
