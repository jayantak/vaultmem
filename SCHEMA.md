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
| `aliases`  | any                 | Alternate names a `[[wikilink]]` may resolve through. |
| `thread`   | Sessions            | The session's own slug (matches its directory name). |

## Status vocabulary

Sessions and Projects carry a `status:`. The live states the picker and
counters use:

- `active` — in progress; shown in the picker, counts toward a project's active tally.
- `parked` — paused; shown in the picker; if untouched past `cold_days` it is
  flagged cold by `groom`.
- `done` — finished; hidden from the picker, and archived to `Sessions/_archive/`
  by `groom`.

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

Two invariants keep glyph-as-presentation from becoming glyph-as-identity:

1. The glyph lives on the **filename and the H1** of a Project (and the H1 of a
   Session), never elsewhere.
2. A Session's `project:` field is the **plain** project name — no glyph. Name
   matching strips a leading glyph before comparing, so a plain-named session
   still binds to a glyph-prefixed project file.

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

## Maps of Content

`MOCs/MOC - <Topic>.md` — one hub note per domain. The first non-frontmatter
blockquote line (`> …`) is the one-liner shown by `mocs` and `index`.

## Wikilink resolution

`[[Target]]` resolves the way Obsidian does, in order: exact relative path
(`Folder/Note` → `Folder/Note.md`), then unique basename (case-insensitive),
then a frontmatter `aliases:` entry. `|display`, `#heading`, and `^block`
suffixes are stripped first. `Templates/` is excluded. No fuzzy matching.
