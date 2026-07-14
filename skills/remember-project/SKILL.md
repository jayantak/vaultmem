---
name: remember-project
description: >
  Build a durable, frugal agent-memory structure in Obsidian for the repository
  you're working in. Use when starting work in a new/unfamiliar repo, when the
  user says "build project memory", "set up agent memory for this repo",
  "onboard this project into Obsidian", "remember this project", or when an
  agent keeps re-deriving the same project context every session. Interviews
  the user in depth, then writes a pointer-based MOC (+ a few signpost notes)
  that route future agents to where truth lives rather than duplicating code.
---

<!-- GENERATED from the private dotfiles source repo — edit there, not here. -->

# Project Memory

Obsidian is your primary agent-memory layer (see `obsidian-vault` and the memory
routing in `~/AGENTS.md`). This
skill builds the memory *for one repository* so any future agent session starts
warm instead of re-deriving context from scratch.

## The one principle: signpost, don't duplicate

The repository is on disk and is the **source of truth for how the code works**.
Obsidian must hold only what the repo *can't tell you*:

- **WHY** — decisions, rejected alternatives, constraints, the rationale a diff never captures.
- **WHERE** — a map: where things live in the repo + the external systems (Linear, Datadog, AWS, dashboards, datalake).
- **GOTCHAS** — operational traps, footguns, "this will bite you" that aren't visible in the code.
- **WHO** — owners, stakeholders, who to ask about what.
- **GLOSSARY** — domain terms and acronyms a newcomer won't know.
- **STATE** — what's in flight right now and where it's heading. Active work
  groups under a **Project note** (`Projects/<name>.md` — the epic tier that
  owns the repo list and whose sessions distill upward; see the `session`
  skill). The MOC is the domain *map* (top tier); link the relevant
  `[[<Project>]]` from the MOC's state section rather than duplicating its
  session log here.

**Never** restate code, API shapes, file contents, or anything regenerable by
reading the repo. Every note points to the authoritative source (a repo path, a
PR, a ticket, a URL) and adds the context that source lacks. If a fact is
trivially re-discoverable in the repo in under a minute, it does not belong in
Obsidian — point at it instead.

## Workflow

1. **Orient + pick the vault (cheap, before asking anything).** Identify the
   repo: name, git remote, primary languages, top-level layout, and existing
   docs (`README`, `docs/`, `adr/`, `CLAUDE.md`/`AGENTS.md`). Read what's there;
   *don't ask the user anything the repo already answers* (grill-me rule).

   **First-run vs. re-sync.** Check whether `MOCs/MOC - <Project>.md` already
   exists in the chosen vault. If it does, this is a **re-sync, not a first
   run** — do NOT re-interview from scratch and do NOT rewrite the hub. Read its
   **drift anchor**, diff the repo against it, and update only what moved. See
   [§ Re-syncing (diff, don't rewrite)](#re-syncing-diff-dont-rewrite) and skip
   the full grill (step 2) in favor of the much shorter re-sync interview there.

   **Choose the target vault** — route by the registry's match rules
   (`vaultmem vaults`); a typical setup has a *work* vault and a
   *personal* vault (see `obsidian-vault`):
   - Work repo (git remote under your work org, or clearly work-related) →
     the **work** vault.
   - Personal / side project (personal account, no work org) → the
     **personal** vault.
   - **Ambiguous → ask.** Even when inferring, state your inference and confirm
     before writing the first note, so a personal project never lands in the
     work vault (or vice-versa).

   Then read the chosen vault's `CLAUDE.md` + `Home.md` and follow *its*
   conventions (each vault's folders and Home differ). If
   that vault has no `MOCs/` folder + `## Maps of Content` layer yet, create it.

2. **Grill — extremely detailed, one question at a time.** Walk the question
   tree in [`references/question-tree.md`](references/question-tree.md). Follow
   the `grill-me` method: ask **one** question at a time, always offer a
   recommended/default answer, and skip any branch the repo already answered in
   step 1. The goal is to extract the non-obvious, in-your-head knowledge —
   not to transcribe the code.

3. **Decide the structure and detail level.** Size the footprint to the project
   using [`references/structure-rubric.md`](references/structure-rubric.md). A
   small/stable repo may warrant only a MOC + a gotchas note. A large, active
   one warrants the full set. Default to *fewer, denser, pointer-first* notes.

4. **Write to the chosen vault.** Use `obsidian-vault` conventions (frontmatter,
   wikilinks, folders, the Agent Index = definition-of-done). Create:
   - `MOCs/MOC - <Project>.md` — the entry-point hub (always).
   - A small set of signpost notes only where step 3 says they're warranted
     (decisions, gotchas/field-guide, glossary, people, where-truth-lives).
   - **Stamp the drift anchor** (always, first run *and* every re-sync): record
     where the memory was last reconciled with the repo so the *next* run can
     diff instead of re-deriving. See [§ Re-syncing](#re-syncing-diff-dont-rewrite).
   - Update the target vault's `Home.md`: add the MOC to the `## Maps of Content`
     section (one line of orientation) and add rows to the Agent Index for any
     new notes.
   - Append to today's daily note in that vault.

5. **Confirm and hand off.** Tell the user what was created and run
   `vaultmem mocs` so they can see it registered.

## Re-syncing (diff, don't rewrite)

A MOC is a snapshot. The repo moves; the snapshot rots. A first run with no way
to tell *what* rotted forces the next run to re-read everything or, worse, to
trust stale "as of" claims. The fix is a **drift anchor**: a small, machine-
checkable record of where the memory was last reconciled with the repo, so any
later run can **diff forward** and touch only what changed.

**Every MOC carries a drift anchor** (first run included — so re-runs have
something to diff against). Put the machine-readable part in frontmatter and a
human/agent-readable "how to re-sync" block in the body:

```yaml
# frontmatter
last_synced: 2026-06-01
synced_commit: ad452a08f      # short SHA the body claims were reconciled to
```

The body block records the *baselines a re-run should diff against* — pick the
handful that actually signal drift for this repo (counts, a release line, the
HEAD it was synced to, the active ticket areas) and the exact command to check
each. Generic skeleton (adapt per repo — see an existing filled-in MOC in your vault for an example):

```markdown
## Drift anchor — re-sync before trusting "as of" claims

Last synced **2026-06-01 @ `ad452a08f`** · <N ADRs> · <release line> · <active areas>.
On a re-run, **diff first, update only what moved, then re-stamp this anchor**:

- Changes since:  `git log ad452a08f..HEAD --oneline`
- New ADRs/docs:  `git diff --name-only ad452a08f..HEAD -- docs/adr/`
- New release line: newest `Production Release: X.Y.Z` vs the one above
- Active-work shift: `git log ad452a08f..HEAD --oneline | grep -oE '\(<TICKET-RE>\)'`
```

**The re-sync interview is short.** Most drift is in the repo (git answers it).
Ask the user only what git *can't*: "since <last_synced>, what changed in the
*why / who / direction* that wouldn't show up in a diff?" (a re-org, a new
owner, a killed initiative, a constraint that lifted). Then:

1. Run the anchor's diff commands; map each changed area to the MOC section it
   affects (new ADRs → Gotchas/decisions; new release line → Active work; new
   ticket prefixes → Active work; moved files → Where-the-truth-lives).
2. **Edit in place**, surgically. Update the drifted lines; do not rewrite
   untouched sections; never duplicate a section "as an update."
3. Re-stamp the anchor (frontmatter `last_synced`/`synced_commit` + the body
   baselines) and bump any "as of YYYY-MM-DD" you touched.
4. If a whole subsystem appeared since last sync, *then* promote it to its own
   signpost note (per the rubric) and link it from the MOC.

Same frugality bias as a first run: point, don't paste; surgical, not wholesale.

## What to create (detail tiers)

| Artifact | Always? | Detail level |
|---|---|---|
| `MOCs/MOC - <Project>.md` | Yes | Map. 1–2 lines of orientation per linked note/section so an agent knows where to dig. Dense pointers, no code. |
| Drift anchor (frontmatter + section in the MOC) | Yes | `last_synced`/`synced_commit` + a "how to re-sync" block with the diff baselines & commands. Lets the next run diff instead of re-deriving. See [§ Re-syncing](#re-syncing-diff-dont-rewrite). |
| Where-truth-lives section (in the MOC) | Yes | Terse routing: repo (+ how to fetch), Linear, Datadog, AWS targets, datalake, dashboards. |
| Decisions / why | If real trade-offs exist | Medium: the decision, the why, what was rejected & why, link to ADR/PR/ticket. No implementation detail. |
| Gotchas / field guide | If operational traps exist | Medium: terse bullets, each "symptom → cause → where to look (repo path)". |
| Glossary | If domain jargon is heavy | Terse: term → one-line meaning → where it lives in code. |
| People / ownership | If >1 stakeholder | Terse: name → role → owns → when to ping. Use `[[People/Name]]`. |

Full rubric (when to create each, how to size by project complexity) is in
[`references/structure-rubric.md`](references/structure-rubric.md).

## Frugality rules

- **Point, don't paste.** A note that reproduces a repo file has failed.
- **One MOC per project** is the entry point; everything hangs off it.
- **Promote, don't pre-build.** Start with the MOC; add signpost notes only as
  the interview surfaces real, durable, non-obvious knowledge.
- **Date what rots.** Anything that will drift (current state, "as of") gets a
  date so a future agent knows to re-verify against the repo.
- **Re-running is a diff, not a rewrite.** On a second pass, read the drift
  anchor, diff the repo against it, and edit only the drifted lines in place —
  then re-stamp the anchor. Never re-interview from scratch or duplicate a
  section. See [§ Re-syncing](#re-syncing-diff-dont-rewrite).
