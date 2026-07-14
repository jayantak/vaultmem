---
name: obsidian-vault
description: >
  Use to reference or update your Obsidian vaults. Trigger when: (1) the user
  asks about a person, project, system, debug pattern, prior note, or topic that
  may be documented — "what do I know about X", "have I noted Y", "check my
  notes"; (1b) reflex — even with no memory question asked, BEFORE you
  investigate a past decision/root cause/incident, explain "why is it built this
  way," or spend more than a couple of tool calls reconstructing project or
  people context, check the vault first (it is ~60ms and ~700 tokens, cheaper
  than reading two files); (2) something worth documenting happens — decisions,
  root causes,
  architecture choices, meetings, tool setup, project milestones, people context,
  generalizable patterns; (3) a parent agent spawns you as a subagent at a
  logical stopping point to capture session work. Capture liberally — the goal
  is extensive knowledge bases for human and agent reference.
---

<!-- GENERATED from the private dotfiles source repo — edit there, not here. -->

# Obsidian Vault

Read from and write to your Obsidian vaults from any project.

## Your Vaults

Never hardcode a vault path or id. Resolve them at runtime: `vaultmem vaults`
prints the registry (id, root path, sessions root, MOC, roles, routing rules),
and `vaultmem path <vault>` prints one root for use in scripts
(`V="$(vaultmem path <vault>)"`). A typical setup has a **work** vault
(debugging, incidents, meetings, projects, architecture, people) and a
**personal** vault (learnings, side projects, ideas, non-work notes).

Default to the work vault unless content is clearly personal. If a topic could plausibly be in either, check both — they're small.

## Agent Index (the entry point)

Each vault's `Home.md` contains an `## Agent Index` section between `<!-- AGENT-INDEX:START -->` and `<!-- AGENT-INDEX:END -->` markers. The index lists every non-Daily non-Template note as a row (`note wikilink | one-sentence summary | tags`), grouped by folder.

**Always start here.** Reading `Home.md` is cheap; the index is small enough to triage without reading any individual note.

These vaults **are** your agent-memory layer (see `AGENTS.md § Agent memory`).
Read the repo on disk for live code; read the vault for the
why/decisions/gotchas/people the code can't tell you.

## Fast search: the `vaultmem` CLI

A ripgrep-backed helper on `PATH` is the quickest way in — no need to read whole
notes to find the right one:

- `vaultmem <query>` — search both vaults; curated Agent-Index/MOC hits first, then note-content matches.
- `vaultmem index` — print the default vault's Agent Index (what exists).
- `vaultmem mocs` — list the Maps of Content (domain hubs).

Use it to locate candidate notes, then read only those. It is the cheap
discovery step before any deeper read.

## Researching by following wikilinks (graph traversal)

These vaults are a *linked graph*, not a flat pile — the highest-signal way to
research a topic is to start at a hub and **follow the `[[wikilinks]]` outward**,
the same way you'd read the code by following imports. Keyword search finds a
note; link-following finds the note's *neighbourhood* (the decisions, gotchas,
and people around it). Use both: search to find the entry note, then traverse.

The `vaultmem` link subcommands do this over ripgrep (no Obsidian app, no
graph DB). All accept a wikilink target — a basename (`Mikey`), a `Folder/Name`
path, or an alias (`Payments`) — or a file path:

- `vaultmem links <note>` — the note's **outbound** `[[links]]`, each resolved to its file (or flagged `DANGLING`).
- `vaultmem backlinks <note>` — notes that link **to** this one (reverse edges; alias-aware). This is how you find "what else touches this".
- `vaultmem neighbors <note>` — outbound + backlinks together (the one-hop view).
- `vaultmem resolve <name>` — resolve a single `[[link]]` to its path; non-zero exit + `DANGLING` if it points nowhere.

**Traversal protocol** (keep it cheap — depth, not breadth):

1. **Pick the entry hub.** `vaultmem mocs` for the domain MOC, or `Home.md`'s Agent Index, or a search hit. MOCs are built to be entry points — start there.
2. **Fan out one hop.** `vaultmem links <hub>` (or `neighbors`). Read the one-line orientation each MOC gives its links; pick the 1–3 that match the question. Don't open everything.
3. **Read those, then traverse again only if needed.** Follow a second hop from a note you actually read. **Stop at ~2 hops** — relevance decays fast and the vault is small.
4. **Use `backlinks` to widen or climb back.** To answer "what depends on / discusses X", `backlinks X` surfaces notes that don't mention X by keyword but point at it.
5. **A `DANGLING` target is a dead end** — don't invent its content; note it (it may be a capture gap worth fixing) and move on.

Prefer this over reading whole folders. For a 3+ note synthesis, hand the
resolved paths to an Explore subagent (see below).

## Maps of Content (the nested layer)

As a vault grows, the flat Agent Index doesn't scale, so domains get a **MOC** —
a hub note in `MOCs/` (`MOC - <Topic>.md`, frontmatter `type: moc`, tag `moc`)
linked from the `## Maps of Content` section of `Home.md`. A MOC is a *map, not
a duplicate*: it links its domain's notes with a line of orientation each, plus a
"where the truth lives" section pointing to the repo and external systems.

Reading order: `Home.md` Maps of Content → the relevant MOC → the specific note
or the repo. **Promote** a domain to a MOC once it passes ~8 related notes, and
add it to `Home.md`. Building a *repository's* MOC + signpost notes is automated
by the `remember-project` skill.

## Workflow A: Reference

Triggered by user questions that might be answered better with prior notes — a person's name, project name, system name, debug pattern, "what do I know about X", "have I noted Y".

1. **Pick the vault.** Work topics → the work vault. Personal → the personal vault. Ambiguous → both.
2. **Read `Home.md`.** Scan only the `## Agent Index` section.
3. **Pick candidates.** Match the topic against title, summary, and tags. Note 0-N candidate paths.
4. **Route by candidate count and depth:**
   - **0 candidates** → tell the user nothing relevant is in the vault, proceed without it.
   - **1-2 candidates with focused content** → read inline and synthesize directly.
   - **3+ candidates OR cross-cutting synthesis** → use a delegated explorer when available, with the candidate paths and a focused question. Otherwise, inspect only the most relevant notes directly.
5. **Cite the notes used** so the user can open them in Obsidian.

### When to dispatch the Explore subagent

Use it any time you'd otherwise be reading 3+ notes, or any single note longer than ~5KB, or any task that requires synthesizing across notes (e.g. "summarize what I know about distributed systems"). Pattern:

```
Ask an explorer to read these vault notes:
- <path1>
- <path2>
- <path3>

Answer: <focused question>. Quote the notes you used.
```

## Workflow B: Capture

Triggered when something worth documenting happens — debug root cause,
architecture decision, incident response, meeting recap, project milestone,
tool/infra setup, people context, generalizable learning, or explicit "make a
note". Also triggered when a parent agent spawns you as a subagent at a logical
stopping point (see Workflow C below).

1. **Pick the vault.** Work content → the work vault. Personal/generalizable → the personal vault.
2. **Read `Home.md`'s Agent Index first.** Search for keywords from the topic. If a related note exists and the new content is on-topic for it, **extend it** (append a dated `### YYYY-MM-DD — <subtopic>` section to the appropriate part of the note). Do not create a sibling.
3. **If no good home exists, create a new note** in the appropriate folder:

   **Work vault folders:** `Debug/`, `Incidents/`, `Meetings/`, `Projects/`, `Architecture/`, `People/`. Naming and template rules are in the vault's `CLAUDE.md`.

   **Personal folders:** `Inbox/` (default if unsure), `Projects/`, `Areas/`, `Resources/`, `Zettelkasten/` (atomic notes — `YYYYMMDDHHMM <Title>.md`). Naming and template rules are in the vault's `CLAUDE.md`.

   **Naming conventions (cross-vault, applied at create time):**
   - **`Meetings/` notes MUST be date-prefixed**: `YYYY-MM-DD - <Title>.md`. Single meetings use the meeting date. Multi-meeting aggregators (timelines, recurring series logs) use the earliest date covered (the file's "since"). This makes the folder sortable chronologically by filename. Apply to subfolders too (`Meetings/Standups/2026-03-18 - platform sync.md`).
   - `Incidents/` notes also date-prefix: `YYYY-MM-DD - <short description>.md` (per the work vault's `CLAUDE.md`).
   - `Debug/`, `Projects/`, `Architecture/`, `People/` notes use descriptive titles, no date prefix (state-tracking notes, not events).
   - When extending an existing un-prefixed `Meetings/` note, leave the filename alone unless the user asks for a rename — don't churn history.

4. **Update the Agent Index in `Home.md`** in the same operation:
   - New note → add a row to the relevant `### <Folder>` subsection. Wikilink, one-sentence summary, tags.
   - Extended note where the summary line is no longer accurate → refresh the existing row's summary.

   The index update is part of the definition-of-done. A capture without an index update is incomplete.

5. **Append to the daily note** in the same vault. See Daily Note Append below.

### Daily Note Append

In the relevant vault, append under `## Notes` in `Daily/YYYY-MM-DD.md`:

```
- **HH:MM** — Brief description → [[Folder/Note Title]]
```

If today's daily note doesn't exist, create it from the vault's `Templates/Daily Note` (work) or `Templates/Daily` (personal). Frontmatter: `title: YYYY-MM-DD`, `date: YYYY-MM-DD`, `tags: [daily]`.

For a Zettelkasten capture in the personal vault, mark it as captured:

```
- **HH:MM** — Captured → [[Zettelkasten/YYYYMMDDHHMM Title]]
```

## Zettelkasten (personal vault only)

Long-lived knowledge graph. Atomic notes in `Zettelkasten/` as a flat folder — structure comes from links, not hierarchy.

**Threshold:** liberal. Capture any idea you might want to find again in 6 months — patterns, mental models, surprising behaviors, trade-off frameworks, workflow insights. Expect 1-3 per active session. If a debug session yields a generalizable lesson (e.g. "socket exhaustion causes OOM under backpressure"), capture it as a personal-vault zettel — even if the debug context was work.

**Atomic note format:**
- Filename: `YYYYMMDDHHMM <Descriptive Title>.md` (current timestamp)
- Frontmatter: `title`, `date`, `type: zettel`, `tags`
- Body: one idea — what is it, why does it matter, when is it useful
- Footer: `## Related` section linking to related zettels and MOCs

**MOCs (Maps of Content):**
- Created when 3+ atomic notes cluster around a theme
- Filename: `MOC - <Topic>.md`
- Frontmatter includes `type: moc` and tag `moc`

**Cross-vault rule:** No cross-vault wikilinks. If a personal-vault zettel was triggered by a work session, mention it in the Related section as plain text, not a link.

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
- **People** links: `[[Name]]` or `[[People/Name|Name]]` (work vault). The note
  must exist in `People/`; if the person has no note yet, create a stub (the
  `Templates/Person.md` shape) or use plain text — don't leave a dangling link.
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

**Definition of done for any link you write:** the target resolves. When you
finish a capture, **verify it** — don't eyeball it:

- `vaultmem resolve "<Target>"` — confirms a single `[[link]]` you wrote
  (e.g. the MOC you filed under, a note you cross-linked) points at a real file.
  Non-zero exit means it dangles; fix the basename or create the target.
- `vaultmem dangling <note>` — lists every broken outbound link in a note
  you just wrote or edited. Run it before declaring the capture done.

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

Each vault's `CLAUDE.md` documents additional conventions (tag prefixes, type fields, etc.). Read it when working in the vault.

## Workflow C: Session Capture (subagent)

Triggered when a parent agent spawns you at a logical stopping point to
capture session work. The parent passes a structured summary (what happened,
key details, category, vault). This is the most common invocation path — agents
are instructed to spawn capture subagents proactively.

1. **Invoke this skill.** The subagent must load the obsidian-vault skill to
   get vault paths, conventions, and workflows.
2. **Parse the parent's summary.** Extract: what happened, category, vault.
3. **Follow Workflow B** from step 1 (pick vault) onward. The category hint
   from the parent maps to folders:
   - `debug` → `Debug/`, `architecture` → `Architecture/`,
     `incident` → `Incidents/`, `meeting` → `Meetings/`,
     `project` → `Projects/`, `people` → `People/`,
     `resource` → `Resources/` (personal), `zettel` → `Zettelkasten/` (personal)
4. **Check for zettel opportunities.** If the work produced a generalizable
   insight (not just a project-specific fact), also create a zettel in the
   personal vault — even if the primary capture goes to the work vault.
5. **Complete all three artifacts:** note (new or extended), Agent Index update,
   daily note append.

### Multiple captures in one invocation

If the parent's summary covers multiple distinct topics (e.g. "fixed a bug AND
decided on a new architecture"), create separate notes for each. Don't merge
unrelated content into one note — atomicity matters.

## When the Skill Is Active But Doesn't Apply

If the user is asking about something that has nothing to do with the vault (a code question with no plausible note), proceed without consulting the vault. The skill being loaded does not mean every response goes through Obsidian.
