---
name: vault-capture
description: >
  Write durable knowledge into the Obsidian vault. Trigger when something worth
  documenting just happened — a root cause, architecture decision, incident,
  meeting, milestone, people context, reusable pattern — on "make a note", on a
  subagent spawned to capture session work, and on repo onboarding ("remember
  this project").
---

<!-- CANONICAL SOURCE: this repo (jayantak/vaultmem). The dotfiles copy under agents-source/skills/ is synced FROM here — edit this file, not that one. -->

# vault-capture — write it down so the next session doesn't re-derive it

The write side of the vault. Finding what's already there is `vault-recall`;
keeping the vault healthy and deciding what's *missing* is `vault-curate`;
per-thread working state is `session`.

## Picking the vault

Never hardcode a vault path or id. `vaultmem vaults` prints the registry (id,
root, sessions root, MOC, roles, routing rules); `vaultmem which` guesses the one
that routes for the current repo/cwd. Work content → the work vault.
Personal/generalizable learning → the personal vault. **Ambiguous → state your
inference and confirm before writing the first note**, so a personal project
never lands in the work vault or vice-versa.

## Workflow B: Capture

Triggered when something worth documenting happens — debug root cause,
architecture decision, incident response, meeting recap, project milestone,
tool/infra setup, people context, generalizable learning, or explicit "make a
note".

1. **Pick the vault** (above).
2. **Check for an existing home first.** `vaultmem <keywords>` from the topic. If a related note exists and the new content is on-topic for it, **extend it** (append a dated `### YYYY-MM-DD — <subtopic>` section to the appropriate part of the note). Do not create a sibling.
3. **If no good home exists, create a new note** — see § Where notes go below for
   how to pick the folder. Do not assume a folder exists; discover the layout.
4. **Update the Agent Index in `Home.md`** in the same operation:
   - New note → add a row to the relevant `### <Section>`: `| [[Folder/Note]] | one-line summary |`. Keep the summary terse — the index is a triage pointer, not a place to read the note.
   - Extended note where the summary line is no longer accurate → refresh the existing row's summary.

   The index update is part of the definition-of-done. A capture without an index update is incomplete.

5. **If the vault keeps a daily log, append to today's entry.** Not every vault
   has one — see § Where notes go.
6. **Verify every link you wrote resolves** — see § Definition of done below.
   This is not optional; it is what separates a real capture from a reported one.

**Read before you edit.** The Edit tool rejects writes to files you have not
read with the Read tool in this conversation — the top recorded tool error in
past sessions. `vaultmem cat`/`bookmark` do **not** satisfy that precondition:
they are separate processes, so the Edit tool does not count them as a read. Use
them for cheap inspection (checking what a note already says before deciding to
extend it), then Read the file itself before the first edit.

## Where notes go

**Never assume a folder exists.** Folder names are configurable per vault, and
the guaranteed contract (SCHEMA.md) is small:

```
<vault-root>/
  Home.md       # the Agent-Index hub
  MOCs/         # Maps of Content — one "MOC - <Topic>.md" per domain hub
  Projects/     # one <name>.md per project (epic); type: project
  Sessions/     # one <thread>/_index.md per session (task)
  Templates/    # excluded from search + resolution
```

That is what `vaultmem init` scaffolds and all this skill can count on.
Everything else is that vault's own convention — **discover the layout, don't
guess it**: `vaultmem index` names the sections this vault actually uses (the
cheapest read), `vaultmem mocs` shows how it carves up topics. A `CLAUDE.md` at
the vault root wins over anything here.

**Choosing a home:**

- A note about an epic → `Projects/`. One task's working state → `Sessions/`
  (the `session` skill owns that tier — don't hand-roll it).
- A domain hub with 8+ related notes under it → `MOCs/MOC - <Topic>.md`.
- Anything else → the existing section whose siblings look most like your note.
  Matching an established section beats inventing a folder. If nothing fits,
  put the note at the vault root and index it — a findable note in the wrong
  place beats a perfect folder nobody searches.

Vaults that already have topical folders (`Debug/`, `Meetings/`, a daily log)
or a Zettelkasten tier have filename and placement conventions that go with
them: [`references/optional-layouts.md`](references/optional-layouts.md).

**Cross-vault rule:** no cross-vault wikilinks — they always dangle. Reference
the other vault as plain text.

## Don't Document

- Routine git commits with no insight beyond the diff
- Ephemeral conversation state (questions asked, tool calls made)
- Facts trivially re-discoverable in under 30 seconds via search

When in doubt, capture it. An extra note is cheap; a lost insight is not.

## Linking Rules

Obsidian wikilinks are not free text — they resolve to a real file or they
dangle. Get this wrong and the link is dead (red in the graph, no backlink).

**How resolution works — the rule that matters most:**

- `[[Target]]` resolves only if some note's **exact basename** (filename minus
  `.md`, case-insensitive) OR a frontmatter **alias** equals `Target`. There is
  no fuzzy match. `[[Payments]]` does NOT find `MOC - Payments.md` unless that note
  has `aliases: [Payments]`.
- **Never invent or paraphrase a link target.** Before writing `[[X]]`, confirm
  `X` is a real basename/alias — `vaultmem mocs` (exact MOC names),
  `vaultmem index` (Agent Index), or `vaultmem <X>`. If you just
  created the note, copy its **exact** title into the pointer; do not retype it
  from memory (this is the #1 source of dangling links — the note gets one name,
  the pointer another).
- `[[Folder/Note]]` and `[[Note]]` resolve to the same file (Obsidian matches on
  basename); the path prefix is optional and only disambiguates duplicate
  basenames. Either is fine as long as the **basename** matches.
- Display text: `[[Real Basename|shown text]]` — the part before `|` must
  resolve; the part after is cosmetic.

**Conventions:**

- All internal vault links use `[[wikilinks]]`. Never markdown-style links for
  vault notes.
- **MOCs** are linked by their real filename `[[MOC - <Topic>]]`, or by a short
  alias the MOC declares (e.g. a `MOC - Payments.md` that declares `aliases: [Payments]`).
  Do not link a bare topic name unless that alias exists.
- **People** links: `[[Name]]` only if a note for that person exists (some
  vaults keep a `People/` folder, many don't). If there is none, create a stub
  from the vault's person template if it has one, or use plain text — don't
  leave a dangling link.
- **Repo artifacts are NOT vault notes.** ADR IDs (`ADR-00093`), source paths
  (`packages/…`), PR numbers (`#3383`) live in the repo, not Obsidian — write
  them as inline code or a real URL, never as `[[wikilinks]]`. `[[ADR-00093]]`
  will always dangle.
- External links (Jira, Datadog, GitHub) use plain URLs or markdown links.
- **No cross-vault wikilinks** — a work↔personal `[[link]]` always dangles. Reference
  the other vault as plain text.
- **Project ↔ Session.** A session links its epic as `**Project:** [[<name>]]`
  where `<name>` is the exact basename of `Projects/<name>.md`. The Project's
  `## Sessions` index links back as `[[<thread>]]`. **That back-link resolves
  only because the session declares `aliases: [<thread>]`** — the session file
  is `Sessions/<thread>/_index.md`, so its basename is `_index`, not the thread
  name. A session without that alias is unlinkable: every `[[<thread>]]` to it
  dangles. Verify both directions — `vaultmem resolve "<name>"` and
  `vaultmem resolve "<thread>"` — before collapsing or committing. Never
  wikilink a Linear issue id or URL (plain text: `PROJ-1234`).

## Definition of done for any link you write: the target resolves

When you finish a capture, **verify it** — don't eyeball it:

- `vaultmem resolve "<Target>"` — confirms a single `[[link]]` you wrote
  (e.g. the MOC you filed under, a note you cross-linked) points at a real file.
  Non-zero exit means it dangles; fix the basename or create the target.
- `vaultmem dangling <note>` — lists every broken outbound link in a note
  you just wrote or edited. Run it before declaring the capture done.
- `vaultmem verify <file>` — the same dangling check plus the `doctor` schema
  lints, scoped to one file. Useful on a Session or Project note, where the
  frontmatter contract is enforced and a missing `aliases:` makes the note
  unlinkable.

This catches the most expensive failure mode in this system: an agent (often a
background capture subagent) **reports creating a note it never wrote**, leaving
the index/MOC wikilinks dangling. If you write `→ promoted to [[X]]` or add a
`[[X]]` to a MOC, `X.md` must exist on disk — `resolve`/`dangling` prove it.
Never trust a subagent's "created the note" claim without a resolve check.

## Frontmatter

At minimum:

```yaml
---
title: Descriptive Title
date: YYYY-MM-DD
tags:
  - relevant-tag
---
```

Sessions and Projects carry additional **required** fields — `thread`/`status`/
`updated` and `aliases` on a Session, `type`/`status` on a Project. SCHEMA.md is
normative there, and `vaultmem doctor` enforces it (see `vault-curate`). If the
vault root has a `CLAUDE.md`/`AGENTS.md`, follow any further conventions it
documents (tag prefixes, type fields); many vaults have none.

## Workflow C: Session Capture (subagent)

Triggered when a parent agent spawns you at a logical stopping point to
capture session work. The parent passes a structured summary (what happened,
key details, category, vault). This is the most common invocation path — agents
are instructed to spawn capture subagents proactively.

1. **Invoke this skill.** The subagent must load `vault-capture` to get vault
   routing, conventions, and the verification contract.
2. **Parse the parent's summary.** Extract: what happened, category, vault.
3. **Follow Workflow B** from step 1 (pick vault) onward. Treat the parent's
   category as a *hint*, not a folder name: resolve it against the sections this
   vault actually has (`vaultmem index`) per § Where notes go. `project` maps to
   the schema's `Projects/`; the rest (`debug`, `architecture`, `incident`,
   `meeting`, `people`, `zettel`, …) only have a folder if this vault made one.
4. **Check for generalizable insight.** If the work produced a lesson that
   outlives the project (not just a project-specific fact), capture it as its own
   note — in the personal vault if that's where durable learning lives, even
   when the primary capture goes to the work vault.
5. **Complete all three artifacts:** note (new or extended), Agent Index update,
   daily note append — then run the resolve/dangling verification above. A
   subagent that reports a note it did not verify is the documented failure mode.

### Multiple captures in one invocation

If the parent's summary covers multiple distinct topics (e.g. "fixed a bug AND
decided on a new architecture"), create separate notes for each. Don't merge
unrelated content into one note — atomicity matters.

## Workflow D: Repo onboarding (project memory)

Triggered by "build project memory", "set up agent memory for this repo",
"onboard this project into Obsidian", "remember this project", starting work in
an unfamiliar repo, or noticing an agent re-derive the same project context
every session. This is a capture with a specific shape: a pointer-based Map of
Content for one repository, so any future session starts warm.

### The one principle: signpost, don't duplicate

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

### Steps

1. **Orient + pick the vault (cheap, before asking anything).** Identify the
   repo: name, git remote, primary languages, top-level layout, and existing
   docs (`README`, `docs/`, `adr/`, `CLAUDE.md`/`AGENTS.md`). Read what's there;
   *don't ask the user anything the repo already answers*.

   **First-run vs. re-sync.** Check whether `MOCs/MOC - <Project>.md` already
   exists in the chosen vault. If it does, this is a **re-sync, not a first
   run** — do NOT re-interview from scratch and do NOT rewrite the hub. Read its
   **drift anchor**, diff the repo against it, and update only what moved. See
   [§ Re-syncing (diff, don't rewrite)](#re-syncing-diff-dont-rewrite) and skip
   the full grill (step 2) in favor of the much shorter re-sync interview there.

   **Choose the target vault** — route by the registry's match rules
   (`vaultmem vaults` / `vaultmem which`): a work repo (git remote under your
   work org, or clearly work-related) → the **work** vault; a personal / side
   project → the **personal** vault; **ambiguous → ask**, stating your inference
   first.

   Then read the chosen vault's `CLAUDE.md` + `Home.md` and follow *its*
   conventions (each vault's folders and Home differ). If that vault has no
   `MOCs/` folder + `## Maps of Content` layer yet, create it.

2. **Grill — extremely detailed, one question at a time.** Walk the question
   tree in [`references/question-tree.md`](references/question-tree.md). Ask
   **one** question at a time, always offer a recommended/default answer, and
   skip any branch the repo already answered in step 1. The goal is to extract
   the non-obvious, in-your-head knowledge — not to transcribe the code.

3. **Decide the structure and detail level.** Size the footprint to the project
   using [`references/structure-rubric.md`](references/structure-rubric.md). A
   small/stable repo may warrant only a MOC + a gotchas note. A large, active
   one warrants the full set. Default to *fewer, denser, pointer-first* notes.

4. **Write to the chosen vault.** Use the conventions above (frontmatter,
   Linking Rules, folders, the Agent Index = definition-of-done). Create:
   - `MOCs/MOC - <Project>.md` — the entry-point hub (always).
   - A small set of signpost notes only where step 3 says they're warranted
     (decisions, gotchas/field-guide, glossary, people, where-truth-lives).
   - **Stamp the drift anchor** (always, first run *and* every re-sync): record
     where the memory was last reconciled with the repo so the *next* run can
     diff instead of re-deriving. See [§ Re-syncing](#re-syncing-diff-dont-rewrite).
   - Update the target vault's `Home.md`: add the MOC to the `## Maps of Content`
     section (one line of orientation) and add rows to the Agent Index for any
     new notes.
   - Append to today's daily note in that vault, if it keeps one.

5. **Confirm and hand off.** Verify the links resolve (§ Definition of done),
   tell the user what was created, and run `vaultmem mocs` so they can see it
   registered.

### Re-syncing (diff, don't rewrite)

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

### What to create (detail tiers)

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

### Frugality rules (repo onboarding)

- **Point, don't paste.** A note that reproduces a repo file has failed.
- **One MOC per project** is the entry point; everything hangs off it.
- **Promote, don't pre-build.** Start with the MOC; add signpost notes only as
  the interview surfaces real, durable, non-obvious knowledge.
- **Date what rots.** Anything that will drift (current state, "as of") gets a
  date so a future agent knows to re-verify against the repo.
- **Re-running is a diff, not a rewrite.** On a second pass, read the drift
  anchor, diff the repo against it, and edit only the drifted lines in place —
  then re-stamp the anchor. Never re-interview from scratch or duplicate a
  section.

## Handing off

- Need to find what's already written before capturing? → `vault-recall`.
- Wondering *what to write next*, or whether the vault is rotting? → `vault-curate`.
- Capturing per-thread working state that must survive `/clear`? → `session`.
