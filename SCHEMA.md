# vaultmem vault schema

The normative contract for what vaultmem reads out of a vault. `vaultmem init`
scaffolds a compliant skeleton; this document is the reference. A vault that
follows it works with every subcommand; deviations degrade gracefully (a missing
`Home.md` just disables the Agent-Index surfaces, a missing field reads empty).

`schema: 1` — the current schema version. Put it in `Home.md`'s frontmatter so a
future tool can warn on an unknown version.

## Vault layout

```
<vault-root>/
  Home.md                 # the Agent-Index hub (gates index/doctor/status/curated search)
  MOCs/                   # Maps of Content — one "MOC - <Topic>.md" per domain hub
  Projects/               # one <name>.md per project (epic); type: project
    _archive/             # groomed (done) projects move here; excluded from every listing
  Sessions/               # one <thread>/_index.md per session (task)
    _archive/             # groomed (done) sessions move here; excluded from every listing
  Templates/              # excluded from search + resolution
    Project.md
    Session _index.md
```

All folder names are configurable per vault (`sessions`, `home`, `mocs` in the
config; see the Config reference in the README). The names above are the
defaults `init` writes and the rest of this document assumes.

## Frontmatter fields the tool reads

Frontmatter is the leading `--- … ---` YAML block. vaultmem reads only scalar
fields (first `key: value` line), stripping surrounding quotes and any trailing
inline ` # comment`. It never parses nested YAML.

| Field      | Where               | Meaning |
|------------|---------------------|---------|
| `schema`   | `Home.md`           | Schema version marker (`1`). |
| `status`   | Projects, Sessions  | Lifecycle state — see the status vocabulary. |
| `updated`  | Sessions            | Real last-touch, `YYYY-MM-DD[ HH:MM]`. Drives staleness/cold-parked math (NOT file mtime, which cloud-drive re-sync rewrites). |
| `project`  | Sessions            | Plain name of the parent Project (no status glyph). `` (empty) = orphan session. |
| `type`     | Projects            | `project` marks a Project note; `moc` marks a Map of Content. |
| `repos`    | Projects            | Repos the project touches (shown by `project <name>`). |
| `linear`   | Projects            | Optional issue/epic reference (shown by `project <name>`). |
| `moc`      | Projects            | Optional `[[MOC - <Topic>]]` backref (shown by `project <name>`). |
| `aliases`  | any                 | Alternate names a `[[wikilink]]` may resolve through. **Required on every Session** (`aliases: [<thread>]`): the file is `_index.md`, not `<thread>.md`, so a Project's `## Sessions` line links `[[<thread>]]` and that only resolves through this alias. `doctor` flags a missing one as `NOALIAS`. |
| `thread`   | Sessions            | The session's own slug (matches its directory name). |

### Required frontmatter

`doctor`'s `MISSING-FM` lint enforces a minimum per note type — absence isn't
just an empty read, it breaks a downstream command:

- **Session** (`_index.md`): `thread`, `status`, `updated`.
- **Project** (`<name>.md`, excluding `type: moc` notes): `type`, `status`.

### `## Bookmark` (Sessions)

The `session` skill's `_index.md` template has a fixed spine of headings
(`Bookmark`, `Pinned`, `Work log`, `Decisions`, `Git state`) — see that skill
for the full template. `doctor`'s `EMPTY-BOOKMARK` lint checks only the
`## Bookmark` heading, and only on `status: active` sessions: it is the always-
current resume pointer, so an active session with nothing under it is a real
gap. The other spine headings ship intentionally empty on a fresh session and
are never linted.

## Status vocabulary

Sessions and Projects carry a `status:`. The live states the picker and
counters use:

- `active` — in progress; shown in the picker, counts toward a project's active
  tally. If a session's `active` status goes untouched past
  `stale_active_days` (`VAULTMEM_STALE_ACTIVE_DAYS`, default 7), `groom`
  reports it as stale-active: it likely stalled and should be parked or
  retired — or flipped to `done` if the work actually finished.
- `parked` — paused; shown in the picker; if untouched past `cold_days` it is
  flagged cold by `groom`.
- `done` — finished; hidden from the picker, and archived to `Sessions/_archive/`
  by `groom`. A Project with `status: done` is archived the same way, into
  `Projects/_archive/`, **unless** a session still points at it (`project:`
  field matches, glyph-stripped) from outside `Sessions/_archive/` — that
  blocks the move and `groom` prints a warning naming the blocking session(s)
  instead, so a project never disappears out from under work still in flight.

`doctor` additionally treats these frontmatter statuses as **dead** when
checking whether an Agent-Index row has gone stale (a row still asserting a live
verdict for a note whose status says it was retracted):
`reverted`, `superseded`, `deprecated`, `done`, `archived`, `cancelled`/`canceled`.

## Status-glyph invariants

Obsidian sorts a folder's sidebar by filename, so a Project (and optionally a
Session) filename may carry a leading status glyph to self-sort by state:

```
Projects/🟢 Widget Pipeline.md
```

Glyph set: `🟢` active · `💤`/`⬜` parked/idle · `✅` done · `🔴` blocked · `🟡` at-risk.

Three invariants keep glyph-as-presentation from becoming glyph-as-identity:

1. The glyph lives on the **filename and the H1** of a Project (and the H1 of a
   Session), never elsewhere.
2. A Session's `project:` field is the **plain** project name — no glyph. Name
   matching strips a leading glyph before comparing, so a plain-named session
   still binds to a glyph-prefixed project file.
3. A **Session folder** (`Sessions/<thread>/`) must never carry a glyph —
   vaultmem keys a session by its folder basename == `thread:`, so a glyphed
   folder desyncs the picker and `groom`. Only the H1 glyphs for a session;
   the file is always `_index.md` and the folder is always the plain thread
   name. `doctor` flags a glyphed session folder as `GLYPHED-FOLDER`, and a
   glyph that disagrees with `status:` as `GLYPH-DESYNC`. The H1 glyph is
   required and always checked (a missing one is a desync); a Project's
   *filename* glyph stays optional per the "may carry" rule above, and is
   checked only when present.

## Agent-Index row grammar

`Home.md` contains the Agent Index between two literal markers:

```markdown
<!-- AGENT-INDEX:START -->

### <Section>
| [[Folder/Note]] | one-line summary of the note |
| [[Folder/Note#heading]] | … |

### <Another Section>
| [[Note]] | … |

<!-- AGENT-INDEX:END -->
```

- Only lines **inside** the markers count as index rows.
- A row begins `| [[` — a Markdown table row whose first cell is a `[[wikilink]]`
  to the note, and whose second cell is a terse one-line summary. The index is a
  triage pointer ("which note?"), not a place to read the note; keep summaries short.
- `### <Section>` headings group rows; `index` shows section counts, `index
  <section>` expands one.
- `doctor` walks each row: **BROKEN** if the `[[wikilink]]` resolves to no note
  or a 0-byte stub; **STALE** if the linked note's `status` is dead but the row
  summary still reads live (contains a live word — verdict/shipped/active/… —
  and no death word).
- `doctor` separately walks `Sessions/` and `Projects/` directly (not via the
  index) for structural corruption — `NOALIAS`, `GLYPH-DESYNC`,
  `GLYPHED-FOLDER`, `NO-UPDATED`, `MISSING-FM`, `EMPTY-BOOKMARK`,
  `INDEX-DRIFT`. See the README's [doctor](README.md#doctor) section for the
  full table and exit codes.

### Project `## Sessions` index rows

A Project note's `## Sessions` section indexes its sessions, one row per
`[[thread]]`, grouped however the project prefers (by status, chronologically,
etc.). The `session` skill appends a row per the shape
`- [[<thread>]] — <one-line> (status: active)`, optionally folding in a
tracker issue id (`(PROJ-1234, active)`); a bare `(active)` is also read. All
three shapes carry the same thing: a trailing status word in the line's last
`(...)` group. `doctor` compares that token against the linked session's own
`status:` frontmatter and flags a disagreement as `INDEX-DRIFT` — read-only,
it never rewrites the Project file. A row reading `archived` is never flagged:
that word marks the session's on-disk location (`Sessions/_archive/<thread>/`)
once `groom` retires it, not a live status — see § Status vocabulary above.

## Maps of Content

`MOCs/MOC - <Topic>.md` — one hub note per domain. The first non-frontmatter
blockquote line (`> …`) is the one-liner shown by `mocs` and `index`.

## Wikilink resolution

`[[Target]]` resolves the way Obsidian does, in order: exact relative path
(`Folder/Note` → `Folder/Note.md`), then unique basename (case-insensitive),
then a frontmatter `aliases:` entry. `|display`, `#heading`, and `^block`
suffixes are stripped first. `Templates/` is excluded. No fuzzy matching.

## Reachability (`doctor --deep`)

`vaultmem doctor --deep` is an opt-in, vault-wide scan (off by default; see
README [doctor --deep](README.md#doctor---deep)) for notes that have fallen
out of the graph: `ORPHAN` (zero inbound `[[wikilinks]]` from anywhere else in
the vault) and `UNINDEXED` (absent from both the primary vault's Agent Index
and every MOC's outbound links). `Home.md`, `MOCs/`, `Templates/`, and
anything under `_archive/` are excluded as candidates — they are hubs,
retired notes, or templates, not orphans by any useful definition. `Sessions/`
and `Projects/` are excluded too: those notes are discovered through the
Project→Session lifecycle tier (`sessions`/`projects`/`project <name>`), not
through the wikilink graph or the Agent Index/MOC system — nothing elsewhere
in this document requires a Session or Project to be MOC-linked or
Agent-Index-listed, so `--deep` does not require it either.
