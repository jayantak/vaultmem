---
name: vault-curate
description: >
  "What should I write next?" and "is the vault rotting?" — vault health and gap
  finding. Trigger on what to document next, where notes are thin, vault
  cleanup / audit / "groom my memory", a recall that came up empty or hit
  `DANGLING`, or a Session/Project note that looks structurally wrong.
---

<!-- CANONICAL SOURCE: this repo (jayantak/vaultmem). The dotfiles copy under agents-source/skills/ is synced FROM here — edit this file, not that one. -->

# vault-curate — what to write next, and what is rotting

`vault-capture` answers "record this." This skill answers the two questions
capture can't: **where is this vault thin, and what is decaying?** Nothing else
in the system owns them. Run it at a stopping point, when the user asks what to
document next, or when a recall attempt came up empty on a topic that should
have been written down.

Vault routing is the same as everywhere: `vaultmem vaults` for the registry,
`vaultmem which` for the vault that routes here. Most commands below take
`-v <vault>` to scope to one.

## The gap surfaces — what should I write next?

- **`vaultmem dangling --by-target`** — every broken `[[link]]` in the vault,
  aggregated by missing target and ranked by inbound count. **This is the
  most-wanted list**: a target three notes point at is one the vault has already
  decided it needs. Write those first. Fixing a `--by-target` entry usually beats
  a new note from nowhere — it completes something already half-written.
- **`vaultmem frontier`** — ranks notes by frontier score (outbound minus inbound
  links, decayed by time since `updated:`). High scorers point outward at things
  nothing points back to — the edge of what's written down. `-n` caps the list.
  Use it when `--by-target` is clean but the vault still feels thin: frontier
  finds the *directions* the vault is reaching toward, not just the named holes.

Read a candidate before writing against it — `vaultmem cat <note> --section
'## <Heading>'` — so a "gap" that is actually covered elsewhere doesn't become a
duplicate. Then hand the actual writing to `vault-capture` (it owns placement,
the Agent-Index update, and the resolve/dangling verification).

**A `DANGLING` target found during traversal is a capture gap.** When
`vault-recall`'s graph walk dead-ends on one, don't invent the missing note's
content — record the target and bring it here; `--by-target` will show whether
anything else wants it too.

## The health surfaces — is the vault rotting?

- **`vaultmem doctor`** — hygiene over the Agent Index plus schema lints on
  Sessions/Projects. Exit 0 clean, 2 on findings. It reports:
  - **BROKEN** — an Agent-Index row whose `[[wikilink]]` resolves to no note or
    to a 0-byte stub. Usually a renamed/moved note, or the fabricated-note
    failure mode (a capture that was reported but never written).
  - **STALE** — a row still reading live (verdict/shipped/active/…) for a note
    whose `status:` says it was retracted (`reverted`, `superseded`,
    `deprecated`, `done`, `archived`, `cancelled`). The note moved on; the index
    still advertises the old answer.
  - **Schema lints** on Sessions/Projects — `NOALIAS` (a session missing
    `aliases: [<thread>]`, which makes every `[[<thread>]]` back-link to it
    dangle), `GLYPH-DESYNC` (an H1/filename status glyph disagreeing with
    `status:`), `GLYPHED-FOLDER` (a `Sessions/<thread>/` folder carrying a glyph
    — it desyncs the picker and `groom`, since sessions are keyed by folder
    basename == `thread:`), `NO-UPDATED`, `MISSING-FM`, `EMPTY-BOOKMARK` (an
    `active` session with nothing under `## Bookmark`), and `INDEX-DRIFT` (a
    Project's `## Sessions` row whose status token disagrees with the linked
    session's own `status:`).
  - **Task lints** on `Tasks/` — `TASK-STATUS` (a status outside
    `backlog|next|active|done`; a typo silently drops the task out of
    `vaultmem next`), `TASK-BLOCKED-DANGLING` (a `blocked_by:` naming a task
    that does not exist, so the task hides behind a dependency nothing can ever
    satisfy), and `TASK-NO-SESSION` (an `active` task with no `session:`
    backlink — a promotion that left no trail to the session now owning it).
- **`vaultmem verify <file>`** — the same dangling check plus the `doctor` schema
  lints, scoped to one file. The fast way to check a single Session or Project
  note you (or a subagent) just wrote, without a vault-wide scan.
- **`vaultmem doctor --deep`** — adds a vault-wide reachability scan: **ORPHAN**
  (zero inbound `[[wikilinks]]` from anywhere else in the vault) and
  **UNINDEXED** (absent from both the Agent Index and every MOC). `Home.md`,
  `MOCs/`, `Templates/`, `Sessions/`, `Projects/`, and anything under
  `_archive/` are excluded as candidates — they are hubs, lifecycle-tier notes,
  retired notes, or templates, not orphans by any useful definition. It is
  slower, so run it deliberately (a periodic audit), not every session.

**Triage order.** BROKEN before STALE before ORPHAN/UNINDEXED: a broken row is a
link that actively lies, a stale row is an answer that has gone wrong, and an
orphan is merely hard to find. Fix a BROKEN row by restoring the target's real
basename (`vaultmem resolve "<name>"` to confirm) or by writing the note that was
never written. Fix STALE by rewriting the row summary to match the note's current
status. Fix ORPHAN/UNINDEXED by linking the note from the MOC or section it
belongs to and adding its Agent-Index row.

`doctor` never rewrites anything — it is read-only by design, including
`INDEX-DRIFT` on a Project file. Every fix is a deliberate edit you make.

## The lifecycle surface — `vaultmem groom`

`groom` is the mechanical half of curation: it retires finished work so the live
surfaces stay small.

- It moves every `done` **session** into `Sessions/_archive/<thread>/` and flips
  its parent Project's `## Sessions` row to `archived`. Safe to run anytime —
  `done` was already distilled at park time.
- It archives every `done` **Project** into `Projects/_archive/` — unless a
  session outside `_archive/` still points at it, in which case it prints a
  warning naming the blocking session(s) instead of moving it. Clear those first
  (archive or reassign the session) and re-run.
- It **lists cold-parked sessions** (parked and untouched past `cold_days`) and
  **stale-active sessions** (`active` but untouched past `stale_active_days`) for
  triage. It never auto-retires them.
- It archives every `done` **task** into `Tasks/_archive/` (a done task has no
  dependents to strand, so nothing blocks the move) and **lists stale backlog** —
  `backlog`/`next` tasks untouched past `VAULTMEM_TASK_STALE_DAYS` (default 14).
  Blocked tasks are exempt: they are waiting on purpose, not rotting. Stale
  backlog matters more than it looks — an unstarted task is the one note type
  nothing else forces you to revisit, and a backlog nobody trusts makes
  `vaultmem next` useless. Promote, re-scope, or delete.

Archived is a **location, not a status**: archived notes drop out of every
listing surface (picker, `projects`, `project`) but wikilinks keep resolving by
basename/alias, so `[[<thread>]]` still works after the move.

Driving the triage itself — resume vs retire, the done-vs-parked decision, and
Project retirement preconditions — belongs to the `session` skill (§ Lifecycle &
grooming). Run `groom` here; take the decisions there.

## A curation pass

When the user asks for a cleanup, an audit, or "what should I write next", run
this in order and report findings rather than silently fixing everything:

1. `vaultmem doctor` — hygiene first. Fix BROKEN, then STALE.
2. `vaultmem dangling --by-target` — the most-wanted list. Propose the top 1–3
   as notes to write.
3. `vaultmem frontier -n 10` — the thin edge, when the named holes are clean.
4. `vaultmem groom` — archive what's finished; surface cold-parked and
   stale-active sessions for triage.
5. Periodically (not every session): `vaultmem doctor --deep` for ORPHAN /
   UNINDEXED notes that have fallen out of the graph.

Orient with `vaultmem index` (section shape) and `vaultmem mocs` (domain hubs)
before deciding where a proposed note would live — a gap that has no obvious home
may really be a missing MOC.

## Handing off

- Actually writing a proposed note (placement, index row, verification) → `vault-capture`.
- Reading candidates before judging a gap → `vault-recall`.
- Deciding resume-vs-retire on a cold-parked or stale-active session, or retiring a Project → `session`.
