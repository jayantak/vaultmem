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

<!-- CANONICAL SOURCE: this repo (jayantak/vaultmem). The dotfiles copy under agents-source/skills/ is synced FROM here — edit this file, not that one. -->

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

Each vault's `Home.md` contains an `## Agent Index` section between
`<!-- AGENT-INDEX:START -->` and `<!-- AGENT-INDEX:END -->` markers: one row per
note (`| [[Folder/Note]] | one-line summary |`), grouped under `### <Section>`
headings.

**Start with `vaultmem index`, not by reading `Home.md`.** It prints the *shape*
— section names with counts, plus the MOC list — and expands on demand. Reading
`Home.md` whole was cheap at 20 notes and stops being cheap fast: on a real
75-note vault `Home.md` is 19,275 bytes while `vaultmem index` gives the same
orientation in 403 — **48× cheaper**, and the gap widens with every note.

- `vaultmem index` — section counts + MOCs. The default first move.
- `vaultmem index <section>` — expand one section's rows (e.g. `index architecture`).
- `vaultmem index all` — full flat dump. An escape hatch, not a default.

Only open `Home.md` directly when you need to *edit* it (adding an index row).

These vaults **are** your agent-memory layer (see `AGENTS.md § Agent memory`).
Read the repo on disk for live code; read the vault for the
why/decisions/gotchas/people the code can't tell you.

## Fast search: the `vaultmem` CLI

A ripgrep-backed helper on `PATH` is the quickest way in — no need to read whole
notes to find the right one. `vaultmem <query>` searches all vaults, curated
Agent-Index/MOC hits first, then note-content matches; `vaultmem mocs` lists the
domain hubs. Locate candidates first, then read only those. Two rules make it
reliable:

- **You are the query expander.** One hopeful query is not a search. Run 2–3
  deliberate variants — the exact term, a synonym, an adjacent concept
  (`drainer` / `OOM` / `memory limit`). Each call is ~60ms; a missed note
  because you stopped at one phrasing is the expensive outcome.
- **Snippets are only leads.** Match lines locate the note; they are not the
  answer. Read the note — or the relevant section, below — before answering.
  Never answer from search output alone.

### Reading a note frugally

Once you have a candidate, don't slurp the file — `vaultmem cat` reads it the way
the graph commands resolve it (basename, `Folder/Name`, or alias, so you needn't
know the path):

- `vaultmem cat <note>` — line-numbered read of the whole note.
- `vaultmem cat <note> --section '## Decisions'` — just that heading block
  (through the next heading of same-or-higher level). Usually all you want.
- `vaultmem cat <note> --from 40 --lines 30` — window the result.

A miss prints up to 3 `Did you mean:` near-matches, so a wrong guess costs one
call instead of a path hunt. For a session's resumable state, `vaultmem bookmark
<thread>` prints only its `## Bookmark` + `## Pinned`.

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

1. **Pick the entry hub.** `vaultmem mocs` for the domain MOC, or `vaultmem index` for the Agent Index, or a search hit. MOCs are built to be entry points — start there.
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

Reading order: `vaultmem mocs` → the relevant MOC → the specific note
or the repo. **Promote** a domain to a MOC once it passes ~8 related notes, and
add it to `Home.md`. Building a *repository's* MOC + signpost notes is automated
by the `remember-project` skill.

## Workflow A: Reference

Triggered by user questions that might be answered better with prior notes — a person's name, project name, system name, debug pattern, "what do I know about X", "have I noted Y".

1. **Pick the vault.** Work topics → the work vault. Personal → the personal vault. Ambiguous → both.
2. **Search, then orient.** `vaultmem <query>` first — it is the fastest path to a
   candidate. If the query is vague ("what do I know about X"), `vaultmem index`
   for the shape, then `vaultmem index <section>` for the one section that matches.
3. **Pick candidates.** Match the topic against title and summary. Note 0-N candidate paths.
4. **Route by candidate count and depth:**
   - **0 candidates** → tell the user nothing relevant is in the vault, proceed without it.
   - **1-2 candidates with focused content** → read inline and synthesize directly.
   - **3+ candidates OR cross-cutting synthesis** → use a delegated explorer when available, with the candidate paths and a focused question. Otherwise, inspect only the most relevant notes directly.
5. **Cite the notes used** so the user can open them in Obsidian.

### When to dispatch the Explore subagent

Use it any time you'd otherwise be reading 3+ notes, or any task that requires
synthesizing across notes (e.g. "summarize what I know about distributed
systems"). For one long note, prefer `vaultmem cat --section` over a subagent.
Pattern:

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
2. **Check for an existing home first.** `vaultmem <keywords>` from the topic. If a related note exists and the new content is on-topic for it, **extend it** (append a dated `### YYYY-MM-DD — <subtopic>` section to the appropriate part of the note). Do not create a sibling.
3. **If no good home exists, create a new note** — see § Where notes go below for
   how to pick the folder. Do not assume a folder exists; discover the layout.
4. **Update the Agent Index in `Home.md`** in the same operation:
   - New note → add a row to the relevant `### <Section>`: `| [[Folder/Note]] | one-line summary |`. Keep the summary terse — the index is a triage pointer, not a place to read the note.
   - Extended note where the summary line is no longer accurate → refresh the existing row's summary.

   The index update is part of the definition-of-done. A capture without an index update is incomplete.

5. **If the vault keeps a daily log, append to today's entry.** Not every vault
   has one — see § Where notes go.

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

That is what `vaultmem init` scaffolds and all this skill can count on. Anything
else is that vault's own convention, so **discover the layout instead of guessing
it**: `vaultmem vaults` (roots, sessions root, MOC, routing), `vaultmem index`
(the section names this vault actually uses — sections generally mirror folders,
making this the cheapest read of the layout), `vaultmem mocs` (how it carves up
topics even when folders are flat). If the vault root has a `CLAUDE.md`/`AGENTS.md`,
follow it — the owner's own naming/template rules win over anything here. Many
vaults have none; don't hunt twice.

**Choosing a home:**

- A note about an epic → `Projects/`. One task's working state → `Sessions/`
  (the `session` skill owns that tier — don't hand-roll it).
- A domain hub with 8+ related notes under it → `MOCs/MOC - <Topic>.md`.
- Anything else → the existing section whose siblings look most like your note.
  Matching an established section beats inventing a folder. If nothing fits and
  there is no catch-all, put the note at the vault root and index it — a findable
  note in the wrong place beats a perfect folder nobody searches.

### Optional layouts — only if your vault already has them

Richer vaults often add topical folders such as `Debug/`, `Incidents/`,
`Meetings/`, `Architecture/`, `People/`, `Areas/`, `Resources/`, or an `Inbox/`.
These are **examples, not requirements** — none is part of the schema. Use one
only when `vaultmem index` or the vault's own `CLAUDE.md` shows it exists. When
they are present: event-shaped notes (`Meetings/`, `Incidents/`) date-prefix the
filename `YYYY-MM-DD - <Title>.md` so the folder sorts chronologically (an
aggregator uses the earliest date it covers); state-tracking notes (`Debug/`,
`Architecture/`, `People/`) use plain descriptive titles; extending an existing
un-prefixed note leaves the filename alone unless asked. If the vault keeps a
daily log (`Daily/YYYY-MM-DD.md`), append
`- **HH:MM** — Brief description → [[Folder/Note Title]]` under `## Notes`,
creating today's entry from its daily template if missing.

### The Zettelkasten pattern (optional)

Some vaults keep a flat folder of atomic notes where structure comes from links
rather than hierarchy — one idea per note, timestamp-named
(`YYYYMMDDHHMM <Title>.md`), frontmatter `type: zettel`, a `## Related` footer.
If a vault has one, it is the right home for *generalizable* insight: a pattern,
mental model, or trade-off framework you'd want again in six months, as distinct
from a project-specific fact. A debug session's durable lesson ("socket
exhaustion causes OOM under backpressure") is a zettel; the ticket it came from
is not. If the vault has no such folder, don't create one unprompted — capture
the insight as an ordinary note and link it from the relevant MOC. The value is
the atomicity and the links, not the folder name.

**Cross-vault rule:** no cross-vault wikilinks — they always dangle. Reference
the other vault as plain text.

## Curation: what should I write next?

Capture answers "record this." These answer "where is this vault thin, and what
is missing?" — run them at a stopping point, or when the user asks what to
document next.

- `vaultmem dangling --by-target` — every broken `[[link]]` aggregated by missing
  target, ranked by inbound count. **The most-wanted list**: a target three notes
  point at is one the vault has already decided it needs. Write those first.
- `vaultmem frontier` — ranks notes by frontier score (outbound minus inbound
  links, decayed by time since `updated:`). High scorers point outward at things
  nothing points back to — the edge of what's written down. `-n` caps it.
- `vaultmem doctor` — hygiene: Agent-Index rows gone BROKEN (target missing or a
  0-byte stub) or STALE (row still reads live for a note whose `status:` says it
  was retracted), plus schema lints over Sessions/Projects. Exit 0 clean, 2 on
  findings. `doctor --deep` adds a vault-wide ORPHAN (no inbound links) and
  UNINDEXED (in neither the Agent Index nor any MOC) scan — slower, so run it
  deliberately, not every session.

Fixing a `--by-target` entry or a BROKEN row usually beats a new note: it
completes something already half-written.

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

**Definition of done for any link you write:** the target resolves. When you
finish a capture, **verify it** — don't eyeball it:

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
normative there, and `vaultmem doctor` enforces it. If the vault root has a
`CLAUDE.md`/`AGENTS.md`, follow any further conventions it documents (tag
prefixes, type fields); many vaults have none.

## Workflow C: Session Capture (subagent)

Triggered when a parent agent spawns you at a logical stopping point to
capture session work. The parent passes a structured summary (what happened,
key details, category, vault). This is the most common invocation path — agents
are instructed to spawn capture subagents proactively.

1. **Invoke this skill.** The subagent must load the obsidian-vault skill to
   get vault paths, conventions, and workflows.
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
   daily note append.

### Multiple captures in one invocation

If the parent's summary covers multiple distinct topics (e.g. "fixed a bug AND
decided on a new architecture"), create separate notes for each. Don't merge
unrelated content into one note — atomicity matters.

## When the Skill Is Active But Doesn't Apply

If the user is asking about something that has nothing to do with the vault (a code question with no plausible note), proceed without consulting the vault. The skill being loaded does not mean every response goes through Obsidian.
