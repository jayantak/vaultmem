#!/usr/bin/env bats

# Unit tests for the vaultmem registry/router/session/graph subcommands.
# Run: bats tests/

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  OM="$ROOT/vaultmem"
  # Isolated fake vaults so tests never touch a real vault. The OBS_* exports are
  # path handles the tests use to build fixtures; the tool itself routes via the
  # registry config seeded in VAULTMEM_CONFIG below.
  export OBS_FLO="$BATS_TEST_TMPDIR/flo"
  export OBS_JAY="$BATS_TEST_TMPDIR/jay"
  export DEV_DIR="$BATS_TEST_TMPDIR/src"
  # Isolated cache dir so `nudge`'s stamp file never touches a real ~/.cache.
  export XDG_CACHE_HOME="$BATS_TEST_TMPDIR/cache"
  mkdir -p "$OBS_FLO" "$OBS_JAY"
  # The vault registry the tool consumes. Two vaults flo/jay with labels + owner
  # routing, so the suite exercises the config path a real user hits.
  export VAULTMEM_CONFIG="$BATS_TEST_TMPDIR/config.toml"
  cat >"$VAULTMEM_CONFIG" <<EOF
[defaults]
vault = "jay"

[vault.flo]
label = "Flo"
path = "$OBS_FLO"
match_owners = "flocasts,flo*"
match_paths = "$DEV_DIR/github.com/flocasts/**"

[vault.jay]
label = "Personal"
path = "$OBS_JAY"
EOF
}

# Print a frontmatter `updated:` timestamp N days in the past, in the
# "YYYY-MM-DD HH:MM" form the session skill stamps. Handles BSD and GNU date.
days_ago() {
  if date -v-1d >/dev/null 2>&1; then
    date -v-"$1"d +"%Y-%m-%d %H:%M"
  else date -d "$1 days ago" +"%Y-%m-%d %H:%M"; fi
}

@test "vaults lists the paths from the registry config" {
  run "$OM" vaults
  [ "$status" -eq 0 ]
  [[ "$output" == *"$BATS_TEST_TMPDIR/flo"* ]]
  [[ "$output" == *"$BATS_TEST_TMPDIR/jay"* ]]
}

@test "vaults lists flo with id/path/Sessions/Home.md fields" {
  run "$OM" vaults
  [ "$status" -eq 0 ]
  # Tab-safe field checks (field 1=id, 2=path, 3=sessions root, 4=default MOC).
  echo "$output" | awk -F'\t' '$1=="flo"{ok = ($3=="Sessions" && $4=="Home.md")} END{exit !ok}'
}

@test "vaults marks jay as default with Sessions/Home.md fields" {
  run "$OM" vaults
  echo "$output" | awk -F'\t' '$1=="jay"{ok = ($3=="Sessions" && $4=="Home.md" && $5=="default")} END{exit !ok}'
}

@test "vaults renders the flo routing rules from config (owners + globs)" {
  run "$OM" vaults
  [ "$status" -eq 0 ]
  echo "$output" | awk -F'\t' '$1=="flo"{ok = ($5=="owners=flocasts,flo* globs='"$DEV_DIR"'/github.com/flocasts/**")} END{exit !ok}'
}

@test "registry: vault ids/labels are config-driven, not hardcoded" {
  # A registry with an arbitrary id + label must surface that label and route
  # `path <id>` to its root — proving nothing is pinned to flo/jay.
  cat >"$VAULTMEM_CONFIG" <<EOF
[vault.work]
label = "Werk"
path = "$OBS_FLO"

[vault.jay]
label = "Personal"
path = "$OBS_JAY"
EOF
  mkdir -p "$OBS_FLO/Sessions/task-1"
  printf -- '---\nstatus: active\n---\n# task-1\n' >"$OBS_FLO/Sessions/task-1/_index.md"
  run "$OM" sessions
  [ "$status" -eq 0 ]
  [[ "$output" == *"Werk:"* ]]
  run "$OM" path work
  [ "$status" -eq 0 ]
  [ "$output" = "$OBS_FLO" ]
}

@test "legacy fallback: no config → env var synthesizes one generic vault" {
  # Point the config at a nonexistent file so the tool takes the legacy path.
  export VAULTMEM_CONFIG="$BATS_TEST_TMPDIR/absent.toml"
  run "$OM" vaults
  [ "$status" -eq 0 ]
  # A single generic `main` vault, path from the legacy env var, no org routing.
  echo "$output" | awk -F'\t' '
    $1=="main"{ m = ($2=="'"$OBS_FLO"'" && $3=="Sessions" && $4=="Home.md" && $5=="default") }
    END{ exit !m }'
  # No org routing in the fallback: unknown cwd resolves to the default vault.
  d="$DEV_DIR/github.com/flocasts/x"
  mkdir -p "$d"
  run "$OM" which "$d"
  # stdout is the id; the low-confidence note goes to stderr
  [ "${lines[0]}" = "main" ]
}

@test "which → flo for a flocasts git remote" {
  repo="$BATS_TEST_TMPDIR/work"
  mkdir -p "$repo"
  git -C "$repo" init -q
  git -C "$repo" remote add origin git@github.com:flocasts/ofp-drs.git
  run "$OM" which "$repo"
  [ "$status" -eq 0 ]
  [ "$output" = "flo" ]
}

@test "which → flo for a https flocasts remote" {
  repo="$BATS_TEST_TMPDIR/work2"
  mkdir -p "$repo"
  git -C "$repo" init -q
  git -C "$repo" remote add origin https://github.com/flocasts/flo360.git
  run "$OM" which "$repo"
  [ "$output" = "flo" ]
}

@test "which → flo for cwd under DEV_DIR flocasts path (no git)" {
  d="$DEV_DIR/github.com/flocasts/some-repo"
  mkdir -p "$d"
  run "$OM" which "$d"
  [ "$output" = "flo" ]
}

@test "which → jay for a non-flo remote" {
  repo="$BATS_TEST_TMPDIR/personal"
  mkdir -p "$repo"
  git -C "$repo" init -q
  git -C "$repo" remote add origin git@github.com:jayantak/dotfiles.git
  run "$OM" which "$repo"
  # stdout is the id; the low-confidence note goes to stderr
  [ "${lines[0]}" = "jay" ]
}

@test "which → jay (default) outside any repo" {
  d="$BATS_TEST_TMPDIR/nowhere"
  mkdir -p "$d"
  run "$OM" which "$d"
  [ "${lines[0]}" = "jay" ]
}

@test "sessions lists threads from both vaults, newest first" {
  mkdir -p "$OBS_FLO/Sessions/old-thread" "$OBS_FLO/Sessions/new-thread" "$OBS_JAY/Sessions/home-lab"
  printf '# old\n' >"$OBS_FLO/Sessions/old-thread/_index.md"
  printf '# new\n' >"$OBS_FLO/Sessions/new-thread/_index.md"
  printf '# lab\n' >"$OBS_JAY/Sessions/home-lab/_index.md"
  # Control mtimes: old-thread older, new-thread newest.
  touch -t 202601010000 "$OBS_FLO/Sessions/old-thread/_index.md"
  touch -t 202606010000 "$OBS_FLO/Sessions/new-thread/_index.md"
  run "$OM" sessions
  [ "$status" -eq 0 ]
  [[ "$output" == *"Flo:"* ]]
  [[ "$output" == *"Personal:"* ]]
  [[ "$output" == *"home-lab"* ]]
  # Newest first: new-thread is position 1, old-thread is position 2.
  [[ "$output" == *"1 new-thread"* ]]
  [[ "$output" == *"2 old-thread"* ]]
  # Each thread is annotated with its age in days, e.g. "new-thread(11d·active)".
  [[ "$output" =~ new-thread\([0-9]+d ]]
}

@test "sessions always prints the picker + agent directive, even with no Sessions dirs" {
  run "$OM" sessions
  [ "$status" -eq 0 ]
  [[ "$output" == *"none yet"* ]]
  [[ "$output" == *"AGENT DIRECTIVE"* ]]
}

@test "sessions appends the agent directive after the thread list" {
  mkdir -p "$OBS_JAY/Sessions/home-lab"
  printf '# lab\n' >"$OBS_JAY/Sessions/home-lab/_index.md"
  run "$OM" sessions
  [ "$status" -eq 0 ]
  [[ "$output" == *"home-lab"* ]]
  [[ "$output" == *"AGENT DIRECTIVE"* ]]
}

@test "sessions uses a custom directive_file when configured" {
  cat >"$VAULTMEM_CONFIG" <<EOF
[defaults]
vault = "jay"
directive_file = "$BATS_TEST_TMPDIR/directive.txt"

[vault.jay]
label = "Personal"
path = "$OBS_JAY"
EOF
  printf 'CUSTOM DIRECTIVE LINE\n' >"$BATS_TEST_TMPDIR/directive.txt"
  run "$OM" sessions
  [ "$status" -eq 0 ]
  [[ "$output" == *"CUSTOM DIRECTIVE LINE"* ]]
  [[ "$output" != *"AGENT DIRECTIVE: resume"* ]]
}

@test "sessions groups threads under their project, active first" {
  mkdir -p "$OBS_JAY/Sessions/add-obs" "$OBS_JAY/Sessions/fix-500" "$OBS_JAY/Sessions/loner"
  cat >"$OBS_JAY/Sessions/add-obs/_index.md" <<'EOF'
---
project: drs-v2
status: active
---
# add-obs
EOF
  cat >"$OBS_JAY/Sessions/fix-500/_index.md" <<'EOF'
---
project: drs-v2
status: done
---
# fix-500
EOF
  printf -- '---\nstatus: active\n---\n# loner\n' >"$OBS_JAY/Sessions/loner/_index.md"
  run "$OM" sessions
  [ "$status" -eq 0 ]
  # project header present, orphan bucket present
  [[ "$output" == *"drs-v2:"* ]]
  [[ "$output" == *"(no project)"* ]]
  # status suffix rendered, e.g. add-obs(0d·active)
  [[ "$output" =~ add-obs\([0-9]+d·active\) ]]
  # still prints the directive
  [[ "$output" == *"AGENT DIRECTIVE"* ]]
}

@test "sessions orders active-containing projects before all-inactive; (no project) last" {
  # Seed two projects in one vault: alphabetically later proj has active, earlier
  # is all-parked. (All-done projects no longer render — done is hidden — so the
  # all-inactive case is now 'all-parked', which the picker still shows.)
  mkdir -p "$OBS_JAY/Sessions/proj-a-task" "$OBS_JAY/Sessions/proj-a-done" "$OBS_JAY/Sessions/proj-z-active"
  cat >"$OBS_JAY/Sessions/proj-a-task/_index.md" <<'EOF'
---
project: proj-a
status: parked
---
# proj-a-task
EOF
  cat >"$OBS_JAY/Sessions/proj-a-done/_index.md" <<'EOF'
---
project: proj-a
status: parked
---
# proj-a-done
EOF
  cat >"$OBS_JAY/Sessions/proj-z-active/_index.md" <<'EOF'
---
project: proj-z
status: active
---
# proj-z-active
EOF
  # Also add an orphan with active status.
  mkdir -p "$OBS_JAY/Sessions/orphan-active"
  printf -- '---\nstatus: active\n---\n# orphan-active\n' >"$OBS_JAY/Sessions/orphan-active/_index.md"

  run "$OM" sessions
  [ "$status" -eq 0 ]

  # All content is there
  [[ "$output" == *"proj-z-active"* ]]
  [[ "$output" == *"proj-a-task"* ]]
  [[ "$output" == *"orphan-active"* ]]

  # Extract just the project headers line to verify order
  # proj-z (has active) should appear before proj-a (all-parked), and (no project) last
  line=$(echo "$output" | grep "Personal:" | head -1)
  [[ "$line" == *"proj-z:"*"proj-a:"*"(no project):"* ]]
}

# --- wikilink graph subcommands (resolve / links / backlinks / dangling) -------

# Build a tiny linked vault: a MOC (with alias), two notes, one dangling link.
seed_graph() {
  mkdir -p "$OBS_FLO/MOCs" "$OBS_FLO/Architecture" "$OBS_FLO/People"
  cat >"$OBS_FLO/MOCs/MOC - Demo.md" <<'EOF'
---
title: MOC - Demo
aliases:
  - Demo
type: moc
---
# MOC — Demo
- [[Architecture/Widget]] orientation line
- [[People/Ada]] the owner
- [[Architecture/Ghost]] not created yet
EOF
  printf -- '---\ntitle: Widget\n---\n# Widget\nSee [[People/Ada]] and [[MOC - Demo]].\n' >"$OBS_FLO/Architecture/Widget.md"
  printf -- '---\ntitle: Ada\n---\n# Ada\nOwns [[Architecture/Widget]].\n' >"$OBS_FLO/People/Ada.md"
}

@test "resolve finds a note by alias" {
  seed_graph
  run "$OM" -v flo resolve "Demo"
  [ "$status" -eq 0 ]
  [[ "$output" == *"MOCs/MOC - Demo.md" ]]
}

@test "resolve finds a note by bare basename" {
  seed_graph
  run "$OM" -v flo resolve "Widget"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Architecture/Widget.md" ]]
}

@test "resolve fails (non-zero) on a dangling target" {
  seed_graph
  run "$OM" -v flo resolve "Ghost"
  [ "$status" -ne 0 ]
  [[ "$output" == *"DANGLING"* ]]
}

@test "links lists outbound links and flags the dangling one" {
  seed_graph
  run "$OM" -v flo links "Demo"
  [ "$status" -eq 0 ]
  [[ "$output" == *"✓ [[Architecture/Widget]]"* ]]
  [[ "$output" == *"✗ [[Architecture/Ghost]]"* ]]
}

@test "backlinks finds notes that link to a target (alias-aware)" {
  seed_graph
  run "$OM" -v flo backlinks "Widget"
  [ "$status" -eq 0 ]
  [[ "$output" == *"MOCs/MOC - Demo.md"* ]]
  [[ "$output" == *"People/Ada.md"* ]]
}

@test "dangling surfaces only the unresolved link" {
  seed_graph
  run "$OM" -v flo dangling
  [ "$status" -eq 0 ]
  [[ "$output" == *"[[Architecture/Ghost]]"* ]]
  [[ "$output" != *"[[Architecture/Widget]]"* ]]
}

@test "dangling ignores shell-snippet false positives" {
  mkdir -p "$OBS_FLO"
  printf -- '# Notes\n```bash\nif [[ -d "$HOME/x" ]]; then echo hi; fi\n```\n' >"$OBS_FLO/snippet.md"
  run "$OM" -v flo dangling
  [ "$status" -eq 0 ]
  [[ "$output" == *"none"* ]]
}

@test "dangling default output is unchanged (source -> target lines)" {
  seed_graph
  run "$OM" -v flo dangling
  [ "$status" -eq 0 ]
  [[ "$output" == *"▸ Dangling wikilinks"* ]]
  [[ "$output" != *"by target"* ]]
  [[ "$output" == *"→ [[Architecture/Ghost]]"* ]]
}

@test "dangling --by-target aggregates by missing target with inbound counts, sorted descending" {
  seed_graph
  # A second reference to the same dangling target, from a different note, so
  # the target's inbound count is 2 (MOC + Widget) vs. any other target's 0/1.
  printf -- '\nAlso see [[Architecture/Ghost]].\n' >>"$OBS_FLO/Architecture/Widget.md"
  run "$OM" -v flo dangling --by-target
  [ "$status" -eq 0 ]
  [[ "$output" == *"▸ Dangling wikilinks — by target"* ]]
  [[ "$output" == *"2  [[Architecture/Ghost]]"* ]]
  # Aggregated: exactly one line for the target, not one per source note.
  ghost_lines=$(printf '%s\n' "$output" | grep -c '\[\[Architecture/Ghost\]\]')
  [ "$ghost_lines" -eq 1 ]
}

@test "dangling --by-target collapses case-variant targets into one row" {
  seed_graph
  # Same missing note referenced with two different casings from two
  # different notes. _resolve_path resolves wikilinks case-insensitively
  # (find -iname), so these are the same dangling target and must collapse
  # into a single aggregated row with count 2, not split into two rows of 1.
  printf -- '\nAlso see [[Architecture/ghost]].\n' >>"$OBS_FLO/Architecture/Widget.md"
  run "$OM" -v flo dangling --by-target
  [ "$status" -eq 0 ]
  ghost_lines=$(printf '%s\n' "$output" | grep -ic '\[\[Architecture/Ghost\]\]')
  [ "$ghost_lines" -eq 1 ]
  [[ "$output" == *"2  [[Architecture/Ghost]]"* ]]
}

@test "dangling --by-target on a clean vault reports none" {
  mkdir -p "$OBS_FLO"
  printf -- '# Notes\nno links here\n' >"$OBS_FLO/clean.md"
  run "$OM" -v flo dangling --by-target
  [ "$status" -eq 0 ]
  [[ "$output" == *"none"* ]]
}

@test "dangling --by-target restricts to a single note when given one" {
  seed_graph
  run "$OM" -v flo dangling --by-target "Demo"
  [ "$status" -eq 0 ]
  [[ "$output" == *"[[Architecture/Ghost]]"* ]]
}

# --- session resume: bookmark ------------------------------------------------

seed_bookmark_session() {
  mkdir -p "$OBS_JAY/Sessions/live-thread" "$OBS_JAY/Sessions/_archive/old-thread"
  cat >"$OBS_JAY/Sessions/live-thread/_index.md" <<'EOF'
---
thread: live-thread
status: active
updated: 2026-07-20
aliases: [live-thread]
---
# live-thread

## Bookmark
Last: did X
Next: do Y

## Pinned
- constant: some value

## Work log
- did stuff

## Decisions
none
EOF
  cat >"$OBS_JAY/Sessions/_archive/old-thread/_index.md" <<'EOF'
---
thread: old-thread
status: done
updated: 2026-06-01
aliases: [old-thread]
---
# old-thread

## Bookmark
Last: closed out
Next: n/a

## Pinned
- constant: archived-const
EOF
}

@test "bookmark prints only the Bookmark and Pinned sections" {
  seed_bookmark_session
  run "$OM" -v jay bookmark live-thread
  [ "$status" -eq 0 ]
  [[ "$output" == *"## Bookmark"* ]]
  [[ "$output" == *"Last: did X"* ]]
  [[ "$output" == *"## Pinned"* ]]
  [[ "$output" == *"constant: some value"* ]]
  [[ "$output" != *"## Work log"* ]]
  [[ "$output" != *"did stuff"* ]]
  [[ "$output" != *"## Decisions"* ]]
}

@test "bookmark resolves an archived session under Sessions/_archive/" {
  seed_bookmark_session
  run "$OM" -v jay bookmark old-thread
  [ "$status" -eq 0 ]
  [[ "$output" == *"## Bookmark"* ]]
  [[ "$output" == *"Last: closed out"* ]]
  [[ "$output" == *"## Pinned"* ]]
  [[ "$output" == *"archived-const"* ]]
}

@test "bookmark errors clearly (nonzero) on an unknown thread" {
  seed_bookmark_session
  run "$OM" -v jay bookmark no-such-thread
  [ "$status" -ne 0 ]
  [[ "$output" == *"no such session"* ]]
  [[ "$output" == *"no-such-thread"* ]]
}

@test "bookmark errors (nonzero) with no thread argument" {
  seed_bookmark_session
  run "$OM" -v jay bookmark
  [ "$status" -ne 0 ]
}

# --- cat: token-frugal sectioned/ranged note read (R9) -------------------------

# A note with nested headings so the same-or-higher-level stop is exercised.
seed_cat_note() {
  mkdir -p "$OBS_JAY/Notes"
  cat >"$OBS_JAY/Notes/Doc.md" <<'EOF'
---
title: Doc
aliases: [DocAlias]
---
# Title
intro line
## Alpha
alpha body
### Sub of Alpha
sub body
more sub
## Beta
beta body
EOF
}

@test "cat prints the whole note line-numbered when no --section is given" {
  seed_cat_note
  run "$OM" -v jay cat Doc
  [ "$status" -eq 0 ]
  # first content line is numbered 1 (the frontmatter ---).
  echo "$output" | grep -qE '^ *1'$'\t''---$'
  [[ "$output" == *"beta body"* ]]
}

@test "cat --section extracts one heading block, stopping at the next same-level heading" {
  seed_cat_note
  run "$OM" -v jay cat Doc --section '## Alpha'
  [ "$status" -eq 0 ]
  [[ "$output" == *"## Alpha"* ]]
  [[ "$output" == *"alpha body"* ]]
  # includes the nested ### sub-heading (lower level does not terminate)…
  [[ "$output" == *"Sub of Alpha"* ]]
  [[ "$output" == *"more sub"* ]]
  # …but stops before the next same-level ## Beta.
  [[ "$output" != *"beta body"* ]]
}

@test "cat --section on a level-1 heading runs to EOF (nothing is same-or-higher)" {
  seed_cat_note
  run "$OM" -v jay cat Doc --section '# Title'
  [ "$status" -eq 0 ]
  [[ "$output" == *"intro line"* ]]
  [[ "$output" == *"beta body"* ]]
}

@test "cat --from/--lines windows the selected lines" {
  seed_cat_note
  run "$OM" -v jay cat Doc --section '## Alpha' --from 2 --lines 1
  [ "$status" -eq 0 ]
  # line 2 of the Alpha block is 'alpha body'; --lines 1 keeps only it.
  [[ "$output" == *"alpha body"* ]]
  [[ "$output" != *"## Alpha"* ]]
  [[ "$output" != *"Sub of Alpha"* ]]
}

@test "cat output is line-numbered (tab-separated leading number)" {
  seed_cat_note
  run "$OM" -v jay cat Doc --section '## Beta'
  [ "$status" -eq 0 ]
  echo "$output" | grep -qE $'\t''## Beta$'
}

@test "cat errors (nonzero) on a missing section" {
  seed_cat_note
  run "$OM" -v jay cat Doc --section '## Nope'
  [ "$status" -ne 0 ]
  [[ "$output" == *"no section"* ]]
}

@test "cat errors (nonzero) with no note argument" {
  seed_cat_note
  run "$OM" -v jay cat
  [ "$status" -ne 0 ]
}

@test "cat rejects a non-numeric --from" {
  seed_cat_note
  run "$OM" -v jay cat Doc --from abc
  [ "$status" -ne 0 ]
}

# --- did-you-mean on a resolve miss (R9): cat + resolve ------------------------

@test "cat on an unresolved note prints up to 3 did-you-mean suggestions" {
  seed_graph
  run "$OM" -v flo cat "Widgett"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Did you mean"* ]]
  [[ "$output" == *"Widget"* ]]
}

@test "resolve on a miss prints did-you-mean suggestions" {
  seed_graph
  run "$OM" -v flo resolve "Widgett"
  [ "$status" -ne 0 ]
  [[ "$output" == *"DANGLING"* ]]
  [[ "$output" == *"Did you mean"* ]]
  [[ "$output" == *"Widget"* ]]
}

@test "did-you-mean matches a frontmatter alias, not just basenames" {
  seed_cat_note
  # 'DocAlia' is close to the alias 'DocAlias' but no basename.
  run "$OM" -v jay cat "DocAlia"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Did you mean"* ]]
  [[ "$output" == *"DocAlias"* ]]
}

@test "did-you-mean caps suggestions at 3" {
  mkdir -p "$OBS_JAY/Notes"
  for n in alpha-note alpha-mem alpha-log alpha-doc alpha-run; do
    printf '# %s\n' "$n" >"$OBS_JAY/Notes/$n.md"
  done
  run "$OM" -v jay resolve "alpha"
  [ "$status" -ne 0 ]
  # count indented suggestion lines under the "Did you mean:" header.
  n=$(echo "$output" | grep -cE '^  alpha-')
  [ "$n" -le 3 ]
  [ "$n" -ge 1 ]
}

# --- search --format cli|json|files (R2) ---------------------------------------

# Two notes with a shared search term; one line carries characters that must be
# JSON-escaped (a double-quote, a backslash, a literal tab) so the hand-rolled
# escaper is exercised.
seed_search_notes() {
  mkdir -p "$OBS_JAY/Notes"
  printf '# One\nplain needle line\na "quoted" needle with a \\slash and\ttab\n' >"$OBS_JAY/Notes/one.md"
  printf '# Two\nanother needle here\n' >"$OBS_JAY/Notes/two.md"
}

@test "search --format files prints bare content-hit paths, no ANSI/curated section" {
  seed_search_notes
  run "$OM" -v jay --format files needle
  [ "$status" -eq 0 ]
  [[ "$output" == *"Notes/one.md"* ]]
  [[ "$output" == *"Notes/two.md"* ]]
  # no human-formatted section headers.
  [[ "$output" != *"Note content matches"* ]]
  [[ "$output" != *"Curated index"* ]]
}

@test "search --format json emits a {file,line,text} array with escaped text" {
  seed_search_notes
  run "$OM" -v jay --format json needle
  [ "$status" -eq 0 ]
  [[ "$output" == "["* ]]
  [[ "$output" == *"\"file\":"* ]]
  [[ "$output" == *"\"line\":"* ]]
  [[ "$output" == *"\"text\":"* ]]
  # the tricky line: a double-quote escaped as \" and a backslash as \\.
  [[ "$output" == *'\"quoted\"'* ]]
  [[ "$output" == *'\\slash'* ]]
}

@test "search --format json validates as JSON (parsed by awk-independent check)" {
  seed_search_notes
  run "$OM" -v jay --format json needle
  [ "$status" -eq 0 ]
  # Balanced single top-level array; every object has all three keys. Count
  # objects by "file": occurrences and opening braces — they must match.
  nfile=$(echo "$output" | grep -o '"file":' | grep -c .)
  nline=$(echo "$output" | grep -o '"line":' | grep -c .)
  ntext=$(echo "$output" | grep -o '"text":' | grep -c .)
  [ "$nfile" -eq "$nline" ]
  [ "$nfile" -eq "$ntext" ]
  [ "$nfile" -ge 3 ]
  [[ "$output" == "["* ]]
  [[ "$output" == *"]" ]]
}

@test "search --format json prints [] on no matches" {
  seed_search_notes
  run "$OM" -v jay --format json zzznomatchzzz
  [ "$status" -eq 0 ]
  [ "$output" = "[]" ]
}

@test "search --format cli is the default (curated + content sections)" {
  seed_search_notes
  run "$OM" -v jay needle
  [ "$status" -eq 0 ]
  [[ "$output" == *"Note content matches"* ]]
}

@test "search rejects an unknown --format value" {
  seed_search_notes
  run "$OM" -v jay --format xml needle
  [ "$status" -ne 0 ]
  [[ "$output" == *"--format"* ]]
}

@test "search --format files honors -n limit" {
  mkdir -p "$OBS_JAY/Notes"
  for i in 1 2 3 4 5; do printf '# n%s\ncommon token\n' "$i" >"$OBS_JAY/Notes/n$i.md"; done
  run "$OM" -v jay -n 2 --format files "common token"
  [ "$status" -eq 0 ]
  n=$(echo "$output" | grep -c 'Notes/n')
  [ "$n" -eq 2 ]
}

# --- search AND semantics (multi-term queries) ---------------------------------

# Three notes: one carries both terms on DIFFERENT lines (the file-level AND
# case), one carries only the first, one only the second.
seed_and_notes() {
  mkdir -p "$OBS_JAY/Notes"
  printf '# both\nherdr pane setup\n\nlater a monitor loop\n' >"$OBS_JAY/Notes/both.md"
  printf '# only-a\nherdr pane setup\n' >"$OBS_JAY/Notes/onlya.md"
  printf '# only-b\na monitor loop\n' >"$OBS_JAY/Notes/onlyb.md"
}

@test "search ANDs multiple terms at file level (terms may be on different lines)" {
  seed_and_notes
  run "$OM" -v jay --format files "herdr monitor"
  [ "$status" -eq 0 ]
  # both.md has the terms on separate lines — the pre-AND whole-query-as-one-regex
  # missed it entirely, and a line-level AND would miss it too.
  [[ "$output" == *"Notes/both.md"* ]]
  [[ "$output" != *"Notes/onlya.md"* ]]
  [[ "$output" != *"Notes/onlyb.md"* ]]
}

@test "search AND is order-independent" {
  seed_and_notes
  run "$OM" -v jay --format files "monitor herdr"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Notes/both.md"* ]]
  [[ "$output" != *"Notes/onlya.md"* ]]
}

@test "search AND narrows: an unmatched term yields no results" {
  seed_and_notes
  run "$OM" -v jay --format files "herdr monitor zzznomatchzzz"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "search collapses repeated whitespace between terms" {
  seed_and_notes
  run "$OM" -v jay --format files "herdr    monitor"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Notes/both.md"* ]]
}

@test "search AND applies in json and cli formats too" {
  seed_and_notes
  run "$OM" -v jay --format json "herdr monitor"
  [ "$status" -eq 0 ]
  [[ "$output" == *"both.md"* ]]
  [[ "$output" != *"onlya.md"* ]]
  # excerpts are OR-matched within the AND-selected files, so a note whose terms
  # sit on different lines still yields match objects.
  [[ "$output" == *"\"text\":"* ]]
  run "$OM" -v jay "herdr monitor"
  [ "$status" -eq 0 ]
  [[ "$output" == *"both.md"* ]]
  [[ "$output" != *"onlya.md"* ]]
}

@test "search names the AND as the cause when a multi-term query finds nothing" {
  seed_and_notes
  run "$OM" -v jay "herdr monitor zzznomatchzzz"
  [ "$status" -eq 0 ]
  # the empty result must be distinguishable from an empty vault.
  [[ "$output" == *"all 3 terms"* ]]
}

@test "search keeps the generic empty message for a single-term miss" {
  seed_and_notes
  run "$OM" -v jay zzznomatchzzz
  [ "$status" -eq 0 ]
  [[ "$output" == *"no content matches"* ]]
  [[ "$output" != *"terms"* ]]
}

@test "search single-term queries are unaffected (no regression)" {
  seed_and_notes
  run "$OM" -v jay --format files herdr
  [ "$status" -eq 0 ]
  [[ "$output" == *"Notes/both.md"* ]]
  [[ "$output" == *"Notes/onlya.md"* ]]
  [[ "$output" != *"Notes/onlyb.md"* ]]
}

@test "search keeps regex working in a term" {
  mkdir -p "$OBS_JAY/Notes"
  printf '# r\nticket AD-459 landed\n' >"$OBS_JAY/Notes/r.md"
  printf '# s\nticket AD-12 landed\n' >"$OBS_JAY/Notes/s.md"
  run "$OM" -v jay --format files 'AD-4[0-9]{2}'
  [ "$status" -eq 0 ]
  [[ "$output" == *"Notes/r.md"* ]]
  [[ "$output" != *"Notes/s.md"* ]]
}

@test "search --exclude still applies to a multi-term AND query" {
  mkdir -p "$OBS_JAY/Notes"
  printf '# keep\nherdr pane\nmonitor loop\n' >"$OBS_JAY/Notes/keep2.md"
  printf '# drop\nherdr pane\nmonitor loop\ndraft marker\n' >"$OBS_JAY/Notes/drop2.md"
  run "$OM" -v jay --format files --exclude draft "herdr monitor"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Notes/keep2.md"* ]]
  [[ "$output" != *"Notes/drop2.md"* ]]
}

# --- search --exclude (R10: minimal exclusion, no query language) --------------

# Two notes both matching the query; only one also carries the excluded term.
seed_exclude_notes() {
  mkdir -p "$OBS_JAY/Notes"
  printf '# keep\nwidget alpha notes\n' >"$OBS_JAY/Notes/keep.md"
  printf '# drop\nwidget alpha but also a draft marker\n' >"$OBS_JAY/Notes/drop.md"
}

@test "search --exclude drops notes whose body also matches the pattern (files)" {
  seed_exclude_notes
  run "$OM" -v jay --format files --exclude draft widget
  [ "$status" -eq 0 ]
  [[ "$output" == *"Notes/keep.md"* ]]
  [[ "$output" != *"Notes/drop.md"* ]]
}

@test "search without --exclude keeps both matching notes (files)" {
  seed_exclude_notes
  run "$OM" -v jay --format files widget
  [ "$status" -eq 0 ]
  [[ "$output" == *"Notes/keep.md"* ]]
  [[ "$output" == *"Notes/drop.md"* ]]
}

@test "search --exclude applies in json format too" {
  seed_exclude_notes
  run "$OM" -v jay --format json --exclude draft widget
  [ "$status" -eq 0 ]
  [[ "$output" == *"keep.md"* ]]
  [[ "$output" != *"drop.md"* ]]
}

@test "search --exclude applies in the default cli format" {
  seed_exclude_notes
  run "$OM" -v jay --exclude draft widget
  [ "$status" -eq 0 ]
  [[ "$output" == *"keep.md"* ]]
  [[ "$output" != *"drop.md"* ]]
}

# --- search phrases (inner double quotes, Obsidian/Google style) ---------------

# adjacent.md has the words next to each other; apart.md only has them scattered.
seed_phrase_notes() {
  mkdir -p "$OBS_JAY/Notes"
  printf '# adjacent\nthe quick brown fox\n' >"$OBS_JAY/Notes/adjacent.md"
  printf '# apart\nquick then brown, far apart\n' >"$OBS_JAY/Notes/apart.md"
}

@test "search treats inner double quotes as a phrase (adjacent words only)" {
  seed_phrase_notes
  run "$OM" -v jay --format files '"quick brown"'
  [ "$status" -eq 0 ]
  [[ "$output" == *"Notes/adjacent.md"* ]]
  [[ "$output" != *"Notes/apart.md"* ]]
}

@test "search without quotes ANDs the same words, matching both notes" {
  seed_phrase_notes
  # the contrast that defines the feature: unquoted = AND (both notes carry both
  # words), quoted = phrase (only the adjacent one).
  run "$OM" -v jay --format files "quick brown"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Notes/adjacent.md"* ]]
  [[ "$output" == *"Notes/apart.md"* ]]
}

@test "search mixes a bare term and a phrase in one query" {
  mkdir -p "$OBS_JAY/Notes"
  printf '# hit\nstag environment\nrunning a dry run now\n' >"$OBS_JAY/Notes/hit.md"
  printf '# miss\nstag environment\ndry then run, apart\n' >"$OBS_JAY/Notes/miss.md"
  run "$OM" -v jay --format files 'stag "dry run"'
  [ "$status" -eq 0 ]
  [[ "$output" == *"Notes/hit.md"* ]]
  [[ "$output" != *"Notes/miss.md"* ]]
}

@test "search recovers from an unterminated quote instead of dropping terms" {
  seed_phrase_notes
  # a stray quote should still search the words after it, never silently drop them.
  run "$OM" -v jay --format files '"quick brown'
  [ "$status" -eq 0 ]
  [[ "$output" == *"Notes/adjacent.md"* ]]
}

# --- frontier (knowledge-frontier ranking: (out-in) * exp(-days/30)) -----------

@test "frontier ranks a high-fanout recently-updated hub above its low-fanout leaves" {
  seed_graph
  # Widget points at Ada + the MOC (out=2); Ada points at Widget (out=1). Both
  # untouched (no updated: → mtime fallback, effectively 0d old since just
  # written), so ranking is driven by (out - in): Widget/MOC out-rank Ada.
  run "$OM" -v flo frontier
  [ "$status" -eq 0 ]
  [[ "$output" == *"Knowledge frontier"* ]]
  [[ "$output" == *"Architecture/Widget.md"* ]]
  [[ "$output" == *"People/Ada.md"* ]]
  # Widget (out=2, has both an outbound to Ada and to the MOC) ranks above Ada
  # (out=1, in=1) in the printed order.
  widget_line=$(echo "$output" | grep -n "Architecture/Widget.md" | head -1 | cut -d: -f1)
  ada_line=$(echo "$output" | grep -n "People/Ada.md" | head -1 | cut -d: -f1)
  [ "$widget_line" -lt "$ada_line" ]
}

@test "frontier excludes Home.md, MOCs/, Templates/, and _archive/" {
  seed_graph
  mkdir -p "$OBS_FLO/Templates" "$OBS_FLO/Sessions/_archive/old"
  printf -- '---\nschema: 1\n---\n# Home\n<!-- AGENT-INDEX:START -->\n<!-- AGENT-INDEX:END -->\n' >"$OBS_FLO/Home.md"
  printf -- '---\ntype: project\n---\n# Template\n' >"$OBS_FLO/Templates/Project.md"
  printf -- '---\nthread: old\nstatus: done\nupdated: 2020-01-01\n---\n# old\n' >"$OBS_FLO/Sessions/_archive/old/_index.md"
  run "$OM" -v flo frontier
  [ "$status" -eq 0 ]
  [[ "$output" != *"Home.md"* ]]
  [[ "$output" != *"MOCs/MOC - Demo.md"* ]]
  [[ "$output" != *"Templates/Project.md"* ]]
  [[ "$output" != *"_archive/old"* ]]
  # The non-excluded notes are still ranked.
  [[ "$output" == *"Architecture/Widget.md"* ]]
}

@test "frontier scores a recently-updated high-fanout note above an old low-fanout one" {
  mkdir -p "$OBS_FLO/Notes"
  printf -- '---\nupdated: %s\n---\n# Hub\n[[Notes/A]] [[Notes/B]] [[Notes/C]]\n' "$(days_ago 1)" >"$OBS_FLO/Notes/Hub.md"
  printf -- '---\nupdated: %s\n---\n# A\n' "$(days_ago 90)" >"$OBS_FLO/Notes/A.md"
  printf -- '---\nupdated: %s\n---\n# B\n' "$(days_ago 90)" >"$OBS_FLO/Notes/B.md"
  printf -- '---\nupdated: %s\n---\n# C\n' "$(days_ago 90)" >"$OBS_FLO/Notes/C.md"
  run "$OM" -v flo frontier
  [ "$status" -eq 0 ]
  first_line=$(echo "$output" | sed -n '2p')
  [[ "$first_line" == *"Notes/Hub.md"* ]]
}

@test "frontier -n caps the result count" {
  mkdir -p "$OBS_FLO/Notes"
  printf -- '# One\n' >"$OBS_FLO/Notes/One.md"
  printf -- '# Two\n' >"$OBS_FLO/Notes/Two.md"
  printf -- '# Three\n' >"$OBS_FLO/Notes/Three.md"
  run "$OM" -v flo -n 1 frontier
  [ "$status" -eq 0 ]
  # header line + exactly one ranked row
  [ "$(echo "$output" | wc -l | tr -d ' ')" -eq 2 ]
}

@test "frontier falls back to file mtime when updated: is missing" {
  mkdir -p "$OBS_FLO/Notes"
  printf -- '# NoUpdated\nplain note, no frontmatter\n' >"$OBS_FLO/Notes/NoUpdated.md"
  run "$OM" -v flo frontier
  [ "$status" -eq 0 ]
  [[ "$output" == *"Notes/NoUpdated.md"* ]]
  # a freshly-written file's mtime is "now" → 0d in the printed row
  [[ "$output" == *"  0d  "*"Notes/NoUpdated.md"* ]]
}

# frontier resolves links through a per-invocation cache (_build_resolve_cache)
# instead of calling _resolve_path per wikilink. These pin the cache to the same
# precedence _resolve_path uses — a divergence silently corrupts inbound counts.

@test "frontier inbound count matches case-insensitive basename resolution" {
  mkdir -p "$OBS_FLO/Notes"
  printf -- '---\nupdated: %s\n---\n# Target\n' "$(days_ago 1)" >"$OBS_FLO/Notes/Target.md"
  # Three linkers spelling the basename with different casing; _resolve_path
  # matches case-insensitively, so Target must count in=3, not in=1.
  printf -- '---\nupdated: %s\n---\n# L1\n[[Target]]\n' "$(days_ago 1)" >"$OBS_FLO/Notes/L1.md"
  printf -- '---\nupdated: %s\n---\n# L2\n[[target]]\n' "$(days_ago 1)" >"$OBS_FLO/Notes/L2.md"
  printf -- '---\nupdated: %s\n---\n# L3\n[[TARGET]]\n' "$(days_ago 1)" >"$OBS_FLO/Notes/L3.md"
  run "$OM" -v flo frontier
  [ "$status" -eq 0 ]
  [[ "$output" == *"in=3"*"Notes/Target.md"* ]]
}

@test "frontier resolves a link that only matches via a frontmatter alias" {
  mkdir -p "$OBS_FLO/Notes"
  printf -- '---\nupdated: %s\naliases: ["Nickname"]\n---\n# RealName\n' "$(days_ago 1)" >"$OBS_FLO/Notes/RealName.md"
  printf -- '---\nupdated: %s\n---\n# Linker\n[[Nickname]]\n' "$(days_ago 1)" >"$OBS_FLO/Notes/Linker.md"
  run "$OM" -v flo frontier
  [ "$status" -eq 0 ]
  # The alias link must land on RealName (in=1); if the cache missed the alias
  # table the link would resolve nowhere and RealName would show in=0.
  [[ "$output" == *"in=1"*"Notes/RealName.md"* ]]
}

@test "frontier resolves a list-form frontmatter alias" {
  mkdir -p "$OBS_FLO/Notes"
  printf -- '---\nupdated: %s\naliases:\n  - Moniker\n---\n# Formal\n' "$(days_ago 1)" >"$OBS_FLO/Notes/Formal.md"
  printf -- '---\nupdated: %s\n---\n# Ref\n[[Moniker]]\n' "$(days_ago 1)" >"$OBS_FLO/Notes/Ref.md"
  run "$OM" -v flo frontier
  [ "$status" -eq 0 ]
  [[ "$output" == *"in=1"*"Notes/Formal.md"* ]]
}

@test "frontier prefers an exact relative-path link over a same-basename note elsewhere" {
  mkdir -p "$OBS_FLO/Notes/Deep" "$OBS_FLO/Other"
  printf -- '---\nupdated: %s\n---\n# Deep dupe\n' "$(days_ago 1)" >"$OBS_FLO/Notes/Deep/Dupe.md"
  printf -- '---\nupdated: %s\n---\n# Other dupe\n' "$(days_ago 1)" >"$OBS_FLO/Other/Dupe.md"
  printf -- '---\nupdated: %s\n---\n# Pointer\n[[Notes/Deep/Dupe]]\n' "$(days_ago 1)" >"$OBS_FLO/Notes/Pointer.md"
  run "$OM" -v flo frontier
  [ "$status" -eq 0 ]
  # The path-qualified link must hit Notes/Deep/Dupe (in=1) and leave the
  # same-basename Other/Dupe untouched (in=0).
  [[ "$output" == *"in=1"*"Notes/Deep/Dupe.md"* ]]
  [[ "$output" == *"in=0"*"Other/Dupe.md"* ]]
}

@test "frontier counts repeated links to one target once per linking note" {
  mkdir -p "$OBS_FLO/Notes"
  printf -- '---\nupdated: %s\n---\n# Popular\n' "$(days_ago 1)" >"$OBS_FLO/Notes/Popular.md"
  # _outbound_targets dedupes within a note, so three mentions in one file is
  # still a single edge — the cache must not change that.
  printf -- '---\nupdated: %s\n---\n# Spammy\n[[Popular]] [[Popular]] [[Popular]]\n' "$(days_ago 1)" >"$OBS_FLO/Notes/Spammy.md"
  run "$OM" -v flo frontier
  [ "$status" -eq 0 ]
  [[ "$output" == *"in=1"*"Notes/Popular.md"* ]]
  [[ "$output" == *"out=1"*"Notes/Spammy.md"* ]]
}

@test "frontier leaves a dangling link uncounted" {
  mkdir -p "$OBS_FLO/Notes"
  printf -- '---\nupdated: %s\n---\n# Hopeful\n[[NoSuchNote]]\n' "$(days_ago 1)" >"$OBS_FLO/Notes/Hopeful.md"
  run "$OM" -v flo frontier
  [ "$status" -eq 0 ]
  # out counts the wikilink even though it resolves nowhere; nothing gains in.
  [[ "$output" == *"out=1"*"Notes/Hopeful.md"* ]]
  [[ "$output" != *"NoSuchNote"* ]]
}

# --- project tier: projects / project verbs --------------------------------

# Seed a vault with one Project note and three sessions (2 under it, 1 orphan).
seed_projects() {
  mkdir -p "$OBS_JAY/Projects" \
    "$OBS_JAY/Sessions/add-obs" "$OBS_JAY/Sessions/fix-500" "$OBS_JAY/Sessions/loner"
  cat >"$OBS_JAY/Projects/drs-v2.md" <<'EOF'
---
type: project
status: active
repos: [ofp-drs]
---
# drs-v2
EOF
  cat >"$OBS_JAY/Sessions/add-obs/_index.md" <<'EOF'
---
thread: add-obs
project: drs-v2
status: active
---
# add-obs
EOF
  cat >"$OBS_JAY/Sessions/fix-500/_index.md" <<'EOF'
---
thread: fix-500
project: drs-v2
status: done
---
# fix-500
EOF
  printf -- '---\nthread: loner\nstatus: active\n---\n# loner\n' >"$OBS_JAY/Sessions/loner/_index.md"
}

@test "projects lists a project with active/total session counts" {
  seed_projects
  run "$OM" -v jay projects
  [ "$status" -eq 0 ]
  [[ "$output" == *"drs-v2"* ]]
  [[ "$output" == *"[active]"* ]]
  # 1 active (add-obs) of 2 total (add-obs + fix-500)
  [[ "$output" == *"1/2 sessions"* ]]
}

@test "projects strips YAML inline comments on frontmatter values" {
  # The shipped Templates/Project.md carries inline comments like
  # `status: active   # active | parked | done`. _fm_field must not leak them
  # into the status, or the [status] display and the active-count both break.
  mkdir -p "$OBS_JAY/Projects" "$OBS_JAY/Sessions/s1"
  cat >"$OBS_JAY/Projects/tmpl.md" <<'EOF'
---
type: project
status: active        # active | parked | done
repos: []             # sessions inherit this
---
# tmpl
EOF
  cat >"$OBS_JAY/Sessions/s1/_index.md" <<'EOF'
---
project: tmpl
status: active        # active | parked | done
---
# s1
EOF
  run "$OM" -v jay projects
  [ "$status" -eq 0 ]
  # status renders clean, not "active   # active | parked | done"
  [[ "$output" == *"tmpl  [active]"* ]]
  [[ "$output" != *"# active"* ]]
  # the commented session status still counts as active
  [[ "$output" == *"1/1 sessions"* ]]
}

@test "project <name> shows repos and groups sessions by status" {
  seed_projects
  run "$OM" -v jay project drs-v2
  [ "$status" -eq 0 ]
  [[ "$output" == *"ofp-drs"* ]]
  [[ "$output" == *"add-obs"* ]]
  [[ "$output" == *"fix-500"* ]]
  # add-obs is active, fix-500 is done — both listed under their status
  [[ "$output" == *"active"* ]]
  [[ "$output" == *"done"* ]]
}

@test "project <name> fails on an unknown project" {
  seed_projects
  run "$OM" -v jay project nope
  [ "$status" -ne 0 ]
}

# --- lifecycle grooming (archive / hide done / cold-parked / nudge) ------------

@test "sessions hides done sessions, keeps active and parked" {
  mkdir -p "$OBS_JAY/Sessions/live" "$OBS_JAY/Sessions/paused" "$OBS_JAY/Sessions/closed"
  printf -- '---\nstatus: active\n---\n# live\n' >"$OBS_JAY/Sessions/live/_index.md"
  printf -- '---\nstatus: parked\n---\n# paused\n' >"$OBS_JAY/Sessions/paused/_index.md"
  printf -- '---\nstatus: done\n---\n# closed\n' >"$OBS_JAY/Sessions/closed/_index.md"
  run "$OM" sessions
  [ "$status" -eq 0 ]
  [[ "$output" == *"live"* ]]
  [[ "$output" == *"paused"* ]]
  [[ "$output" != *"closed"* ]]
}

@test "sessions excludes archived sessions under _archive/" {
  mkdir -p "$OBS_JAY/Sessions/live" "$OBS_JAY/Sessions/_archive/oldie"
  printf -- '---\nstatus: active\n---\n# live\n' >"$OBS_JAY/Sessions/live/_index.md"
  printf -- '---\nstatus: done\n---\n# oldie\n' >"$OBS_JAY/Sessions/_archive/oldie/_index.md"
  run "$OM" sessions
  [ "$status" -eq 0 ]
  [[ "$output" == *"live"* ]]
  [[ "$output" != *"oldie"* ]]
}

@test "groom archives done sessions into _archive and flips the Project status" {
  mkdir -p "$OBS_JAY/Projects" "$OBS_JAY/Sessions/keep-me" "$OBS_JAY/Sessions/wrap-up"
  cat >"$OBS_JAY/Projects/proj.md" <<'EOF'
---
type: project
status: active
---
# proj
## Sessions
- [[keep-me]] — ongoing (status: active)
- [[wrap-up]] — shipped (status: done)
EOF
  printf -- '---\nproject: proj\nstatus: active\n---\n# keep-me\n' >"$OBS_JAY/Sessions/keep-me/_index.md"
  printf -- '---\nproject: proj\nstatus: done\n---\n# wrap-up\n' >"$OBS_JAY/Sessions/wrap-up/_index.md"
  run "$OM" -v jay groom
  [ "$status" -eq 0 ]
  [[ "$output" == *"wrap-up"* ]]
  # done session moved under _archive/, active one untouched
  [ -f "$OBS_JAY/Sessions/_archive/wrap-up/_index.md" ]
  [ ! -e "$OBS_JAY/Sessions/wrap-up" ]
  [ -f "$OBS_JAY/Sessions/keep-me/_index.md" ]
  # Project index line for the archived thread flipped to archived
  grep -q '\[\[wrap-up\]\].*archived)' "$OBS_JAY/Projects/proj.md"
  # the active thread's status is left alone
  grep -q '\[\[keep-me\]\].*active)' "$OBS_JAY/Projects/proj.md"
}

@test "groom reports parked sessions older than the cold threshold via updated:" {
  mkdir -p "$OBS_JAY/Sessions/cold-one" "$OBS_JAY/Sessions/fresh-one"
  printf -- '---\nstatus: parked\nupdated: %s\n---\n# cold-one\n' "$(days_ago 40)" >"$OBS_JAY/Sessions/cold-one/_index.md"
  printf -- '---\nstatus: parked\nupdated: %s\n---\n# fresh-one\n' "$(days_ago 2)" >"$OBS_JAY/Sessions/fresh-one/_index.md"
  run "$OM" -v jay groom
  [ "$status" -eq 0 ]
  # 40d-old parked is flagged cold; 2d-old is not
  [[ "$output" == *"cold-one"* ]]
  [[ "$output" != *"fresh-one"* ]]
}

@test "groom cold threshold honors VAULTMEM_COLD_DAYS" {
  mkdir -p "$OBS_JAY/Sessions/p10"
  printf -- '---\nstatus: parked\nupdated: %s\n---\n# p10\n' "$(days_ago 10)" >"$OBS_JAY/Sessions/p10/_index.md"
  # default 21 → not cold
  run "$OM" -v jay groom
  [[ "$output" != *"p10"* ]]
  # threshold 7 → now cold
  VAULTMEM_COLD_DAYS=7 run "$OM" -v jay groom
  [[ "$output" == *"p10"* ]]
}

@test "groom cold threshold reads cold_days from the config default" {
  cat >"$VAULTMEM_CONFIG" <<EOF
[defaults]
vault = "jay"
cold_days = 7

[vault.jay]
label = "Personal"
path = "$OBS_JAY"
EOF
  mkdir -p "$OBS_JAY/Sessions/p10"
  printf -- '---\nstatus: parked\nupdated: %s\n---\n# p10\n' "$(days_ago 10)" >"$OBS_JAY/Sessions/p10/_index.md"
  run "$OM" -v jay groom
  # 10d old with a config cold_days=7 → flagged cold
  [[ "$output" == *"p10"* ]]
}

@test "groom archives a done project with no live sessions into Projects/_archive/" {
  mkdir -p "$OBS_JAY/Projects" "$OBS_JAY/Sessions/_archive/old-thread"
  cat >"$OBS_JAY/Projects/finished.md" <<'EOF'
---
type: project
status: done
---
# finished
EOF
  # its only session is already archived — nothing live blocks the project
  printf -- '---\nproject: finished\nstatus: done\n---\n# old-thread\n' \
    >"$OBS_JAY/Sessions/_archive/old-thread/_index.md"
  run "$OM" -v jay groom
  [ "$status" -eq 0 ]
  [[ "$output" == *"archived project finished"* ]]
  [ -f "$OBS_JAY/Projects/_archive/finished.md" ]
  [ ! -e "$OBS_JAY/Projects/finished.md" ]
}

@test "groom does not archive a done project blocked by a live (non-archived) session" {
  mkdir -p "$OBS_JAY/Projects" "$OBS_JAY/Sessions/still-going"
  cat >"$OBS_JAY/Projects/half-done.md" <<'EOF'
---
type: project
status: done
---
# half-done
EOF
  printf -- '---\nproject: half-done\nstatus: parked\n---\n# still-going\n' \
    >"$OBS_JAY/Sessions/still-going/_index.md"
  run "$OM" -v jay groom
  [ "$status" -eq 0 ]
  # warning names the blocking session, project file untouched
  [[ "$output" == *"NOT archiving half-done"* ]]
  [[ "$output" == *"still-going"* ]]
  [ -f "$OBS_JAY/Projects/half-done.md" ]
  [ ! -e "$OBS_JAY/Projects/_archive/half-done.md" ]
}

@test "archived projects are excluded from the projects listing" {
  mkdir -p "$OBS_JAY/Projects/_archive"
  cat >"$OBS_JAY/Projects/live-one.md" <<'EOF'
---
type: project
status: active
---
# live-one
EOF
  cat >"$OBS_JAY/Projects/_archive/gone.md" <<'EOF'
---
type: project
status: done
---
# gone
EOF
  run "$OM" -v jay projects
  [ "$status" -eq 0 ]
  [[ "$output" == *"live-one"* ]]
  [[ "$output" != *"gone"* ]]
}

@test "archived projects are excluded from project <name> lookup" {
  mkdir -p "$OBS_JAY/Projects/_archive"
  cat >"$OBS_JAY/Projects/_archive/gone.md" <<'EOF'
---
type: project
status: done
---
# gone
EOF
  run "$OM" -v jay project gone
  [ "$status" -ne 0 ]
}

@test "groom reports active sessions stale past the default 7-day threshold" {
  mkdir -p "$OBS_JAY/Sessions/stale-one" "$OBS_JAY/Sessions/fresh-active"
  printf -- '---\nproject: p\nstatus: active\nupdated: %s\n---\n# stale-one\n' \
    "$(days_ago 10)" >"$OBS_JAY/Sessions/stale-one/_index.md"
  printf -- '---\nstatus: active\nupdated: %s\n---\n# fresh-active\n' \
    "$(days_ago 1)" >"$OBS_JAY/Sessions/fresh-active/_index.md"
  run "$OM" -v jay groom
  [ "$status" -eq 0 ]
  [[ "$output" == *"Stale active"* ]]
  [[ "$output" == *"stale-one"* ]]
  [[ "$output" == *"p"* ]]
  [[ "$output" != *"fresh-active"* ]]
}

@test "groom stale-active threshold honors VAULTMEM_STALE_ACTIVE_DAYS" {
  mkdir -p "$OBS_JAY/Sessions/a3"
  printf -- '---\nstatus: active\nupdated: %s\n---\n# a3\n' "$(days_ago 3)" >"$OBS_JAY/Sessions/a3/_index.md"
  # default 7 → not stale
  run "$OM" -v jay groom
  [[ "$output" != *"a3"* ]]
  # threshold 2 → now stale
  VAULTMEM_STALE_ACTIVE_DAYS=2 run "$OM" -v jay groom
  [[ "$output" == *"a3"* ]]
}

# Print $1 lines of filler text (for building an over-threshold _index.md).
filler_lines() {
  local i
  for ((i = 0; i < "$1"; i++)); do printf 'line %d\n' "$i"; done
}

@test "groom reports active/parked sessions past the default 150-line bloat threshold" {
  mkdir -p "$OBS_JAY/Sessions/big-active" "$OBS_JAY/Sessions/small-active"
  {
    printf -- '---\nproject: p\nstatus: active\nupdated: %s\n---\n# big-active\n' "$(days_ago 1)"
    filler_lines 200
  } >"$OBS_JAY/Sessions/big-active/_index.md"
  printf -- '---\nstatus: active\nupdated: %s\n---\n# small-active\n' "$(days_ago 1)" \
    >"$OBS_JAY/Sessions/small-active/_index.md"
  run "$OM" -v jay groom
  [ "$status" -eq 0 ]
  [[ "$output" == *"Checkpoint due"* ]]
  [[ "$output" == *"big-active"* ]]
  [[ "$output" == *"p"* ]]
  [[ "$output" != *"small-active"* ]]
}

@test "groom bloat threshold honors VAULTMEM_BLOAT_LINES" {
  mkdir -p "$OBS_JAY/Sessions/mid-parked"
  {
    printf -- '---\nstatus: parked\nupdated: %s\n---\n# mid-parked\n' "$(days_ago 1)"
    filler_lines 60
  } >"$OBS_JAY/Sessions/mid-parked/_index.md"
  # default 150 → not over threshold
  run "$OM" -v jay groom
  [[ "$output" != *"mid-parked"* ]]
  # threshold 50 → now over
  VAULTMEM_BLOAT_LINES=50 run "$OM" -v jay groom
  [[ "$output" == *"mid-parked"* ]]
}

@test "groom bloat threshold reads bloat_lines from the config default" {
  cat >"$VAULTMEM_CONFIG" <<EOF
[defaults]
vault = "jay"
bloat_lines = 50

[vault.jay]
label = "Personal"
path = "$OBS_JAY"
EOF
  mkdir -p "$OBS_JAY/Sessions/mid-parked2"
  {
    printf -- '---\nstatus: parked\nupdated: %s\n---\n# mid-parked2\n' "$(days_ago 1)"
    filler_lines 60
  } >"$OBS_JAY/Sessions/mid-parked2/_index.md"
  run "$OM" -v jay groom
  [[ "$output" == *"mid-parked2"* ]]
}

@test "groom bloat check ignores done sessions and sessions under _archive/" {
  mkdir -p "$OBS_JAY/Sessions/big-done" "$OBS_JAY/Sessions/_archive/big-archived"
  {
    printf -- '---\nstatus: done\nupdated: %s\n---\n# big-done\n' "$(days_ago 1)"
    filler_lines 200
  } >"$OBS_JAY/Sessions/big-done/_index.md"
  {
    printf -- '---\nstatus: active\nupdated: %s\n---\n# big-archived\n' "$(days_ago 1)"
    filler_lines 200
  } >"$OBS_JAY/Sessions/_archive/big-archived/_index.md"
  run "$OM" -v jay groom
  [ "$status" -eq 0 ]
  [[ "$output" != *"Checkpoint due"* ]]
}

@test "status surfaces a checkpoint-due nudge when a session exceeds the bloat threshold" {
  printf -- '---\nschema: 1\n---\n# Home\n<!-- AGENT-INDEX:START -->\n<!-- AGENT-INDEX:END -->\n' >"$OBS_FLO/Home.md"
  mkdir -p "$OBS_JAY/Sessions/bloaty"
  {
    printf -- '---\nstatus: active\nupdated: %s\n---\n# bloaty\n' "$(days_ago 1)"
    filler_lines 200
  } >"$OBS_JAY/Sessions/bloaty/_index.md"
  run "$OM" status
  [ "$status" -eq 0 ]
  [[ "$output" == *"checkpoint due"* ]]
}

@test "status surfaces a short groom-nudge count including stale-active" {
  # status gates on the PRIMARY vault's Home.md (first vault in the registry,
  # "flo" here); the nudge itself scans every vault, so the stale session can
  # live in jay as long as flo's Home.md exists to pass the fail-quiet gate.
  printf -- '---\nschema: 1\n---\n# Home\n<!-- AGENT-INDEX:START -->\n<!-- AGENT-INDEX:END -->\n' >"$OBS_FLO/Home.md"
  mkdir -p "$OBS_JAY/Sessions/stale-two"
  printf -- '---\nstatus: active\nupdated: %s\n---\n# stale-two\n' "$(days_ago 10)" >"$OBS_JAY/Sessions/stale-two/_index.md"
  run "$OM" status
  [ "$status" -eq 0 ]
  [[ "$output" == *"active stale"* ]]
}

@test "sessions nudges when grooming is due, silent otherwise" {
  mkdir -p "$OBS_JAY/Sessions/live"
  printf -- '---\nstatus: active\n---\n# live\n' >"$OBS_JAY/Sessions/live/_index.md"
  run "$OM" sessions
  [[ "$output" != *"groom"* ]]
  # add a done session → nudge appears pointing at groom
  mkdir -p "$OBS_JAY/Sessions/closed"
  printf -- '---\nstatus: done\n---\n# closed\n' >"$OBS_JAY/Sessions/closed/_index.md"
  run "$OM" sessions
  [[ "$output" == *"groom"* ]]
}

@test "nudge is silent with no vault configured (fail-quiet)" {
  export VAULTMEM_CONFIG="$BATS_TEST_TMPDIR/absent.toml"
  unset OBS_FLO OBS_JAY
  run "$OM" nudge
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "nudge is silent on first-ever call and plants the stamp" {
  printf -- '---\nschema: 1\n---\n# Home\n<!-- AGENT-INDEX:START -->\n<!-- AGENT-INDEX:END -->\n' >"$OBS_FLO/Home.md"
  [ ! -e "$XDG_CACHE_HOME/vaultmem/nudge-stamp" ]
  run "$OM" nudge
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ -e "$XDG_CACHE_HOME/vaultmem/nudge-stamp" ]
}

@test "nudge stays silent when no note changed since the stamp" {
  printf -- '---\nschema: 1\n---\n# Home\n<!-- AGENT-INDEX:START -->\n<!-- AGENT-INDEX:END -->\n' >"$OBS_FLO/Home.md"
  run "$OM" nudge # plants the stamp
  [ "$status" -eq 0 ]
  run "$OM" nudge # nothing touched since → still silent
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "nudge stays silent when the touched note is the session's own _index.md" {
  printf -- '---\nschema: 1\n---\n# Home\n<!-- AGENT-INDEX:START -->\n<!-- AGENT-INDEX:END -->\n' >"$OBS_FLO/Home.md"
  mkdir -p "$OBS_JAY/Sessions/live"
  printf -- '---\nstatus: active\n---\n# live\n' >"$OBS_JAY/Sessions/live/_index.md"
  run "$OM" nudge # plants the stamp
  [ "$status" -eq 0 ]
  sleep 1
  printf -- '---\nstatus: active\nupdated: %s\n---\n# live\n## Work log\n- did stuff\n' \
    "$(date +"%Y-%m-%d %H:%M")" >"$OBS_JAY/Sessions/live/_index.md"
  run "$OM" nudge
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "nudge fires when a vault note changed but no _index.md was touched" {
  printf -- '---\nschema: 1\n---\n# Home\n<!-- AGENT-INDEX:START -->\n<!-- AGENT-INDEX:END -->\n' >"$OBS_FLO/Home.md"
  mkdir -p "$OBS_JAY/Sessions/live" "$OBS_JAY/Projects"
  printf -- '---\nstatus: active\n---\n# live\n' >"$OBS_JAY/Sessions/live/_index.md"
  run "$OM" nudge # plants the stamp
  [ "$status" -eq 0 ]
  sleep 1
  printf -- '---\ntype: project\nstatus: active\n---\n# Notes\nsome content\n' >"$OBS_JAY/Projects/Notes.md"
  run "$OM" nudge
  [ "$status" -eq 0 ]
  [[ "$output" == *"_index.md"* ]]
}

@test "path prints the flo vault root" {
  run "$OM" path flo
  [ "$status" -eq 0 ]
  [ "$output" = "$BATS_TEST_TMPDIR/flo" ]
}

@test "path prints the jay vault root and accepts the personal alias" {
  run "$OM" path jay
  [ "$status" -eq 0 ]
  [ "$output" = "$BATS_TEST_TMPDIR/jay" ]
  run "$OM" path personal
  [ "$output" = "$BATS_TEST_TMPDIR/jay" ]
}

@test "path errors with usage on a bad vault id" {
  run "$OM" path nope
  [ "$status" -eq 2 ]
  [[ "$output" == *"usage: vaultmem path"* ]]
}

# --- status-glyph filenames (sidebar sorting) ---------------------------------
# A project file may carry a leading status glyph in its name ("🟢 <name>.md")
# so Obsidian's sidebar self-sorts by state. Sessions still reference the plain
# `project:` name, so name-matching must strip the glyph.

@test "projects matches sessions to a glyph-prefixed project file" {
  mkdir -p "$OBS_JAY/Projects" "$OBS_JAY/Sessions/build-it"
  cat >"$OBS_JAY/Projects/🟢 Widget Pipeline.md" <<'EOF'
---
aliases: ["Widget Pipeline"]
type: project
status: active
---
# 🟢 Widget Pipeline
EOF
  printf -- '---\nproject: Widget Pipeline\nstatus: active\nupdated: %s\n---\n# build-it\n' \
    "$(days_ago 0)" >"$OBS_JAY/Sessions/build-it/_index.md"
  run "$OM" -v jay projects
  [ "$status" -eq 0 ]
  [[ "$output" == *"🟢 Widget Pipeline"* ]]
  # the plain-named session still counts under the glyphed project
  [[ "$output" == *"1/1 sessions"* ]]
}

@test "groom flips the Sessions index in a glyph-prefixed project file" {
  mkdir -p "$OBS_JAY/Projects" "$OBS_JAY/Sessions/wrap-up"
  cat >"$OBS_JAY/Projects/✅ Widget Pipeline.md" <<'EOF'
---
aliases: ["Widget Pipeline"]
type: project
status: done
---
# ✅ Widget Pipeline
## Sessions
- [[wrap-up]] — shipped (status: done)
EOF
  printf -- '---\nproject: Widget Pipeline\nstatus: done\n---\n# wrap-up\n' \
    >"$OBS_JAY/Sessions/wrap-up/_index.md"
  run "$OM" -v jay groom
  [ "$status" -eq 0 ]
  [ -f "$OBS_JAY/Sessions/_archive/wrap-up/_index.md" ]
  # the project was `done` with no remaining live sessions once wrap-up archived,
  # so it is archived too in the same groom pass — flip happened before the move.
  [ -f "$OBS_JAY/Projects/_archive/✅ Widget Pipeline.md" ]
  [ ! -e "$OBS_JAY/Projects/✅ Widget Pipeline.md" ]
  grep -q '\[\[wrap-up\]\].*archived)' "$OBS_JAY/Projects/_archive/✅ Widget Pipeline.md"
}

# --- init (scaffold config + vault skeleton) -----------------------------------

@test "init --config writes a starter config to VAULTMEM_CONFIG" {
  export VAULTMEM_CONFIG="$BATS_TEST_TMPDIR/fresh/config.toml"
  run "$OM" init --config
  [ "$status" -eq 0 ]
  [ -f "$VAULTMEM_CONFIG" ]
  # the starter config parses clean under the doctor lint
  run "$OM" doctor
  [ "$status" -eq 0 ]
}

@test "init --config refuses to clobber an existing config" {
  # setup() already wrote a config at VAULTMEM_CONFIG
  run "$OM" init --config
  [ "$status" -ne 0 ]
  [[ "$output" == *"already exists"* ]]
}

@test "init scaffolds a SCHEMA-compliant vault skeleton" {
  run "$OM" init --vault jay
  [ "$status" -eq 0 ]
  [ -f "$OBS_JAY/Home.md" ]
  [ -d "$OBS_JAY/MOCs" ]
  [ -d "$OBS_JAY/Projects" ]
  [ -d "$OBS_JAY/Sessions" ]
  [ -f "$OBS_JAY/Templates/Project.md" ]
  [ -f "$OBS_JAY/Templates/Session _index.md" ]
  # Home carries the empty Agent-Index markers and the schema marker
  grep -q 'AGENT-INDEX:START' "$OBS_JAY/Home.md"
  grep -q 'AGENT-INDEX:END' "$OBS_JAY/Home.md"
  grep -q '^schema: 1' "$OBS_JAY/Home.md"
}

@test "init on an already-scaffolded vault does not clobber Home.md" {
  printf -- '---\nschema: 1\n---\n# Home\nMY NOTES\n<!-- AGENT-INDEX:START -->\n<!-- AGENT-INDEX:END -->\n' >"$OBS_JAY/Home.md"
  run "$OM" init --vault jay
  [ "$status" -eq 0 ]
  grep -q 'MY NOTES' "$OBS_JAY/Home.md"
}

# --- doctor config lint (mis-parse fails loudly) -------------------------------

@test "doctor is clean on the seeded config" {
  run "$OM" doctor
  [ "$status" -eq 0 ]
}

@test "doctor accepts a config carrying the bloat_lines default key" {
  cat >"$VAULTMEM_CONFIG" <<EOF
[defaults]
vault = "jay"
bloat_lines = 200

[vault.jay]
label = "Personal"
path = "$OBS_JAY"
EOF
  run "$OM" doctor
  [ "$status" -eq 0 ]
}

@test "doctor hard-errors on an unknown config key" {
  cat >"$VAULTMEM_CONFIG" <<EOF
[vault.jay]
label = "Personal"
path = "$OBS_JAY"
bogus = "nope"
EOF
  run "$OM" doctor
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown key"* ]]
  [[ "$output" == *"bogus"* ]]
}

@test "doctor hard-errors on an unquoted string value" {
  cat >"$VAULTMEM_CONFIG" <<EOF
[vault.jay]
label = Personal
path = "$OBS_JAY"
EOF
  run "$OM" doctor
  [ "$status" -ne 0 ]
  [[ "$output" == *"unquoted string value"* ]]
}

@test "doctor hard-errors on an array-of-tables" {
  cat >"$VAULTMEM_CONFIG" <<EOF
[[vault.jay]]
path = "$OBS_JAY"
EOF
  run "$OM" doctor
  [ "$status" -ne 0 ]
  [[ "$output" == *"array-of-tables"* ]]
}

@test "doctor hard-errors on a nested table" {
  cat >"$VAULTMEM_CONFIG" <<EOF
[vault.jay.sub]
path = "$OBS_JAY"
EOF
  run "$OM" doctor
  [ "$status" -ne 0 ]
  [[ "$output" == *"nested section"* ]]
}

# --- doctor schema lints (P1) + exit codes (A4) ---------------------------------
# Reusable healthy fixture: an active session that follows the real session
# skill template exactly (aliases set, updated set, H1 glyph matches status,
# Bookmark filled in, every other spine heading intentionally empty) — every
# schema-lint test below starts from this and corrupts exactly one thing, so a
# passing "does NOT fire" test proves no false positive on a normal session.
write_healthy_session() { # $1 = thread name
  local t="$1"
  mkdir -p "$OBS_JAY/Sessions/$t"
  cat >"$OBS_JAY/Sessions/$t/_index.md" <<EOF
---
thread: $t
project: Demo
status: active
aliases: [$t]
updated: $(days_ago 0)
---
# 🟢 $t
**Goal:** test session

## Bookmark
Last: did a thing · Next: do another · Open: none

## Pinned

## Work log

## Decisions

## Git state
| Repo | Branch / worktree | PR | State |
|---|---|---|---|
EOF
}

@test "doctor: clean healthy session + project produce no schema findings" {
  write_healthy_session good-thread
  mkdir -p "$OBS_JAY/Projects"
  cat >"$OBS_JAY/Projects/🟢 Demo.md" <<'EOF'
---
type: project
status: active
---
# 🟢 Demo

## Sessions
- [[good-thread]] — testing (status: active)
EOF
  run "$OM" doctor
  [ "$status" -eq 0 ]
  [[ "$output" == *"clean"* ]]
}

@test "doctor NOALIAS: session _index.md missing aliases: [<thread>] fires" {
  write_healthy_session no-alias-thread
  # drop the aliases line
  sed -i.bak '/^aliases:/d' "$OBS_JAY/Sessions/no-alias-thread/_index.md"
  run "$OM" doctor
  [ "$status" -eq 2 ]
  [[ "$output" == *"NOALIAS"* ]]
  [[ "$output" == *"no-alias-thread"* ]]
}

@test "doctor NOALIAS: does not fire when aliases include the thread name" {
  write_healthy_session has-alias-thread
  run "$OM" doctor
  [[ "$output" != *"NOALIAS"* ]]
}

@test "doctor GLYPH-DESYNC: session H1 glyph disagreeing with status: fires" {
  write_healthy_session desync-thread
  sed -i.bak 's/^# 🟢 desync-thread/# 💤 desync-thread/' "$OBS_JAY/Sessions/desync-thread/_index.md"
  run "$OM" doctor
  [ "$status" -eq 2 ]
  [[ "$output" == *"GLYPH-DESYNC"* ]]
  [[ "$output" == *"desync-thread"* ]]
}

@test "doctor GLYPH-DESYNC: a missing H1 glyph on a status-bearing session fires" {
  write_healthy_session noglyph-thread
  sed -i.bak 's/^# 🟢 noglyph-thread/# noglyph-thread/' "$OBS_JAY/Sessions/noglyph-thread/_index.md"
  run "$OM" doctor
  [ "$status" -eq 2 ]
  [[ "$output" == *"GLYPH-DESYNC"* ]]
}

@test "doctor GLYPH-DESYNC: project filename+H1 glyph disagreeing with status: fires" {
  mkdir -p "$OBS_JAY/Projects"
  cat >"$OBS_JAY/Projects/🟢 Widget.md" <<'EOF'
---
type: project
status: parked
---
# 🟢 Widget
EOF
  run "$OM" doctor
  [ "$status" -eq 2 ]
  [[ "$output" == *"GLYPH-DESYNC"* ]]
  [[ "$output" == *"Widget"* ]]
}

@test "doctor GLYPH-DESYNC: does not fire when session H1 glyph matches status" {
  write_healthy_session synced-thread
  run "$OM" doctor
  [[ "$output" != *"GLYPH-DESYNC"* ]]
}

# The filename glyph is OPTIONAL (SCHEMA.md § Status-glyph invariants: a Project
# filename *may* carry one). A glyph-less filename with a correct H1 is fully
# schema-legal and must stay clean — otherwise the lint fires on every vault
# that never adopted the filename convention.
@test "doctor GLYPH-DESYNC: does not fire on a project with no filename glyph" {
  mkdir -p "$OBS_JAY/Projects"
  cat >"$OBS_JAY/Projects/Widget.md" <<'EOF'
---
type: project
status: active
---
# 🟢 Widget
EOF
  run "$OM" doctor
  [ "$status" -eq 0 ]
  [[ "$output" != *"GLYPH-DESYNC"* ]]
}

@test "doctor GLYPH-DESYNC: fires on a wrong filename glyph even when the H1 is right" {
  mkdir -p "$OBS_JAY/Projects"
  cat >"$OBS_JAY/Projects/💤 Widget.md" <<'EOF'
---
type: project
status: active
---
# 🟢 Widget
EOF
  run "$OM" doctor
  [ "$status" -eq 2 ]
  [[ "$output" == *"GLYPH-DESYNC"* ]]
}

@test "doctor GLYPHED-FOLDER: a session folder carrying a status glyph fires" {
  write_healthy_session "glyphed-folder-thread"
  mv "$OBS_JAY/Sessions/glyphed-folder-thread" "$OBS_JAY/Sessions/🟢 glyphed-folder-thread"
  run "$OM" doctor
  [ "$status" -eq 2 ]
  [[ "$output" == *"GLYPHED-FOLDER"* ]]
  [[ "$output" == *"glyphed-folder-thread"* ]]
}

@test "doctor GLYPHED-FOLDER: does not fire on a plain (unglyphed) session folder" {
  write_healthy_session plain-folder-thread
  run "$OM" doctor
  [[ "$output" != *"GLYPHED-FOLDER"* ]]
}

@test "doctor NO-UPDATED: session _index.md missing updated: fires" {
  write_healthy_session no-updated-thread
  sed -i.bak '/^updated:/d' "$OBS_JAY/Sessions/no-updated-thread/_index.md"
  run "$OM" doctor
  [ "$status" -eq 2 ]
  [[ "$output" == *"NO-UPDATED"* ]]
  [[ "$output" == *"no-updated-thread"* ]]
}

@test "doctor NO-UPDATED: an unparseable updated: value fires" {
  write_healthy_session bad-updated-thread
  sed -i.bak 's/^updated:.*/updated: not-a-date/' "$OBS_JAY/Sessions/bad-updated-thread/_index.md"
  run "$OM" doctor
  [ "$status" -eq 2 ]
  [[ "$output" == *"NO-UPDATED"* ]]
}

@test "doctor NO-UPDATED: does not fire when updated: is a valid date" {
  write_healthy_session valid-updated-thread
  run "$OM" doctor
  [[ "$output" != *"NO-UPDATED"* ]]
}

@test "doctor MISSING-FM: session missing thread/status/updated all fire together" {
  mkdir -p "$OBS_JAY/Sessions/bare-thread"
  printf -- '---\nproject: Demo\n---\n# bare-thread\n' >"$OBS_JAY/Sessions/bare-thread/_index.md"
  run "$OM" doctor
  [ "$status" -eq 2 ]
  [[ "$output" == *"MISSING-FM"* ]]
  [[ "$output" == *"bare-thread"* ]]
  [[ "$output" == *"thread"* ]]
  [[ "$output" == *"status"* ]]
  [[ "$output" == *"updated"* ]]
}

@test "doctor MISSING-FM: project missing type: and status: fires" {
  mkdir -p "$OBS_JAY/Projects"
  printf -- '# Untyped Project\n' >"$OBS_JAY/Projects/Untyped.md"
  run "$OM" doctor
  [ "$status" -eq 2 ]
  [[ "$output" == *"MISSING-FM"* ]]
  [[ "$output" == *"Untyped"* ]]
  [[ "$output" == *"type"* ]]
}

@test "doctor MISSING-FM: does not fire when all required fields are present" {
  write_healthy_session complete-thread
  mkdir -p "$OBS_JAY/Projects"
  cat >"$OBS_JAY/Projects/🟢 Demo2.md" <<'EOF'
---
type: project
status: active
---
# 🟢 Demo2
EOF
  run "$OM" doctor
  [[ "$output" != *"MISSING-FM"* ]]
}

@test "doctor EMPTY-BOOKMARK: an active session with an empty Bookmark fires" {
  write_healthy_session empty-bookmark-thread
  # Blank out only the Bookmark body, leaving the other intentionally-empty
  # template headings (Pinned/Work log/Decisions/Git state) as-is.
  awk '
    /^## Bookmark/{print; print ""; f=1; next}
    f && /^## /{f=0}
    f{next}
    {print}
  ' "$OBS_JAY/Sessions/empty-bookmark-thread/_index.md" >"$OBS_JAY/Sessions/empty-bookmark-thread/_index.md.new"
  mv "$OBS_JAY/Sessions/empty-bookmark-thread/_index.md.new" "$OBS_JAY/Sessions/empty-bookmark-thread/_index.md"
  run "$OM" doctor
  [ "$status" -eq 2 ]
  [[ "$output" == *"EMPTY-BOOKMARK"* ]]
  [[ "$output" == *"empty-bookmark-thread"* ]]
}

@test "doctor EMPTY-BOOKMARK: does not fire on a healthy new session (Pinned/Work log/Decisions/Git state empty by template, Bookmark filled)" {
  write_healthy_session fresh-thread
  run "$OM" doctor
  [[ "$output" != *"EMPTY-BOOKMARK"* ]]
}

@test "doctor EMPTY-BOOKMARK: does not fire on a parked session with an empty Bookmark (active-only lint)" {
  write_healthy_session parked-empty-bookmark
  sed -i.bak 's/^status: active/status: parked/; s/^# 🟢 parked-empty-bookmark/# 💤 parked-empty-bookmark/' \
    "$OBS_JAY/Sessions/parked-empty-bookmark/_index.md"
  awk '
    /^## Bookmark/{print; print ""; f=1; next}
    f && /^## /{f=0}
    f{next}
    {print}
  ' "$OBS_JAY/Sessions/parked-empty-bookmark/_index.md" >"$OBS_JAY/Sessions/parked-empty-bookmark/_index.md.new"
  mv "$OBS_JAY/Sessions/parked-empty-bookmark/_index.md.new" "$OBS_JAY/Sessions/parked-empty-bookmark/_index.md"
  run "$OM" doctor
  [[ "$output" != *"EMPTY-BOOKMARK"* ]]
}

@test "doctor exit codes: 0 = clean" {
  write_healthy_session clean-thread
  run "$OM" doctor
  [ "$status" -eq 0 ]
}

@test "doctor exit codes: 1 = config errors only, no drift" {
  cat >"$VAULTMEM_CONFIG" <<EOF
[vault.jay]
label = "Personal"
path = "$OBS_JAY"
bogus = "nope"
EOF
  run "$OM" doctor
  [ "$status" -eq 1 ]
}

@test "doctor exit codes: 2 = schema lint drift only, config clean" {
  write_healthy_session drift-only-thread
  sed -i.bak '/^aliases:/d' "$OBS_JAY/Sessions/drift-only-thread/_index.md"
  run "$OM" doctor
  [ "$status" -eq 2 ]
}

@test "doctor exit codes: 3 = both config errors and drift (bitwise OR of 1 and 2)" {
  write_healthy_session both-thread
  sed -i.bak '/^aliases:/d' "$OBS_JAY/Sessions/both-thread/_index.md"
  cat >"$VAULTMEM_CONFIG" <<EOF
[vault.jay]
label = "Personal"
path = "$OBS_JAY"
bogus = "nope"
EOF
  run "$OM" doctor
  [ "$status" -eq 3 ]
}

# --- doctor vault-growth watch (R6: the ripgrep/FTS5 tripwire) ------------------

@test "doctor prints a per-vault growth line with a note count and search timing" {
  # Three notes in jay; the growth line must count them and time a search.
  mkdir -p "$OBS_JAY/Notes"
  printf 'the quick brown fox\n' >"$OBS_JAY/Notes/a.md"
  printf 'another the note\n' >"$OBS_JAY/Notes/b.md"
  printf 'a third the note\n' >"$OBS_JAY/Notes/c.md"
  run "$OM" doctor
  [[ "$output" == *"Vault growth"* ]]
  # jay: 3 notes · search <n>s  — count exact, timing a decimal-seconds token.
  echo "$output" | grep -E '^  jay: 3 notes · search [0-9]+\.[0-9]+s$'
}

@test "doctor growth count excludes Templates/ and _archive/ notes" {
  mkdir -p "$OBS_JAY/Notes" "$OBS_JAY/Templates" "$OBS_JAY/Sessions/_archive/old"
  printf 'real\n' >"$OBS_JAY/Notes/real.md"
  printf 'tmpl\n' >"$OBS_JAY/Templates/Session.md"
  printf 'gone\n' >"$OBS_JAY/Sessions/_archive/old/_index.md"
  run "$OM" doctor
  # Only the one real note counts, not the template or the archived session.
  echo "$output" | grep -E '^  jay: 1 notes · '
}

@test "doctor growth line is informational — it does not change the exit code" {
  # A clean vault stays exit 0 even though the growth line prints.
  write_healthy_session clean-growth-thread
  run "$OM" doctor
  [ "$status" -eq 0 ]
  [[ "$output" == *"Vault growth"* ]]
}

@test "doctor -v <id> scopes the growth line to the selected vault only" {
  mkdir -p "$OBS_JAY/Notes" "$OBS_FLO/Notes"
  printf 'j\n' >"$OBS_JAY/Notes/j.md"
  printf 'f\n' >"$OBS_FLO/Notes/f.md"
  run "$OM" -v jay doctor
  [[ "$output" == *"  jay: "* ]]
  [[ "$output" != *"  flo: "* ]]
}

# --- doctor INDEX-DRIFT (P2: Project<->Session index drift) ---------------------

@test "doctor INDEX-DRIFT: '(status: active)' row disagrees with the session's actual status: fires" {
  write_healthy_session drift-thread
  sed -i.bak 's/^status: active/status: parked/' "$OBS_JAY/Sessions/drift-thread/_index.md"
  mkdir -p "$OBS_JAY/Projects"
  cat >"$OBS_JAY/Projects/Demo.md" <<'EOF'
---
type: project
status: active
---
# Demo

## Sessions
- [[drift-thread]] — testing (status: active)
EOF
  run "$OM" doctor
  [ "$status" -eq 2 ]
  [[ "$output" == *"INDEX-DRIFT"* ]]
  [[ "$output" == *"drift-thread"* ]]
}

@test "doctor INDEX-DRIFT: '(PROJ-123, active)' row shape disagrees with the session's actual status: fires" {
  write_healthy_session ticket-thread
  sed -i.bak 's/^status: active/status: done/' "$OBS_JAY/Sessions/ticket-thread/_index.md"
  mkdir -p "$OBS_JAY/Projects"
  cat >"$OBS_JAY/Projects/Demo.md" <<'EOF'
---
type: project
status: active
---
# Demo

## Sessions
- [[ticket-thread]] — testing (PROJ-123, active)
EOF
  run "$OM" doctor
  [ "$status" -eq 2 ]
  [[ "$output" == *"INDEX-DRIFT"* ]]
  [[ "$output" == *"ticket-thread"* ]]
}

@test "doctor INDEX-DRIFT: bare '(active)' row shape disagrees with the session's actual status: fires" {
  write_healthy_session bare-thread
  sed -i.bak 's/^status: active/status: parked/' "$OBS_JAY/Sessions/bare-thread/_index.md"
  mkdir -p "$OBS_JAY/Projects"
  cat >"$OBS_JAY/Projects/Demo.md" <<'EOF'
---
type: project
status: active
---
# Demo

## Sessions
- [[bare-thread]] — testing (active)
EOF
  run "$OM" doctor
  [ "$status" -eq 2 ]
  [[ "$output" == *"INDEX-DRIFT"* ]]
  [[ "$output" == *"bare-thread"* ]]
}

@test "doctor INDEX-DRIFT: does not fire when the row status token agrees with the session's status:" {
  write_healthy_session agree-thread
  mkdir -p "$OBS_JAY/Projects"
  cat >"$OBS_JAY/Projects/Demo.md" <<'EOF'
---
type: project
status: active
---
# Demo

## Sessions
- [[agree-thread]] — testing (status: active)
EOF
  run "$OM" doctor
  [[ "$output" != *"INDEX-DRIFT"* ]]
}

@test "doctor INDEX-DRIFT: does not fire on an archived session whose row correctly reads 'archived'" {
  write_healthy_session archived-thread
  sed -i.bak 's/^status: active/status: done/' "$OBS_JAY/Sessions/archived-thread/_index.md"
  mkdir -p "$OBS_JAY/Sessions/_archive"
  mv "$OBS_JAY/Sessions/archived-thread" "$OBS_JAY/Sessions/_archive/archived-thread"
  mkdir -p "$OBS_JAY/Projects"
  cat >"$OBS_JAY/Projects/Demo.md" <<'EOF'
---
type: project
status: active
---
# Demo

## Sessions
- [[archived-thread]] — testing (status: archived)
EOF
  run "$OM" doctor
  [[ "$output" != *"INDEX-DRIFT"* ]]
}

# --- doctor --deep (P3: orphans + unindexed) ------------------------------------

@test "doctor --deep ORPHAN: a note with zero inbound wikilinks fires" {
  mkdir -p "$OBS_JAY/Notes"
  printf -- '# Lonely Note\nno one links here.\n' >"$OBS_JAY/Notes/Lonely.md"
  run "$OM" doctor --deep
  [ "$status" -eq 2 ]
  [[ "$output" == *"ORPHAN"* ]]
  [[ "$output" == *"Lonely"* ]]
}

@test "doctor --deep ORPHAN: does not fire on a note linked from elsewhere in the vault" {
  mkdir -p "$OBS_JAY/Notes"
  printf -- '# Linked Note\ncontent.\n' >"$OBS_JAY/Notes/Linked.md"
  printf -- '# Linker\nsee [[Linked]].\n' >"$OBS_JAY/Notes/Linker.md"
  run "$OM" doctor --deep
  echo "$output" | grep -qE '^\s*\[ORPHAN\]\s+Notes/Linked(\.md)?\s*$' && exit 1
  true
}

@test "doctor --deep ORPHAN: skips Home.md, MOCs/, Templates/, and _archive/ (hubs/retired, not orphans)" {
  mkdir -p "$OBS_JAY/MOCs" "$OBS_JAY/Templates" "$OBS_JAY/Sessions/_archive/old-thread" "$OBS_JAY/Projects/_archive"
  printf -- '# MOC - Topic\n' >"$OBS_JAY/MOCs/MOC - Topic.md"
  printf -- '# Session Template\n' >"$OBS_JAY/Templates/Session _index.md"
  printf -- '---\nthread: old-thread\nstatus: done\n---\n# old-thread\n' >"$OBS_JAY/Sessions/_archive/old-thread/_index.md"
  printf -- '---\ntype: project\nstatus: done\n---\n# Retired\n' >"$OBS_JAY/Projects/_archive/Retired.md"
  run "$OM" doctor --deep
  [[ "$output" != *"MOC - Topic"* ]]
  [[ "$output" != *"Session Template"* ]]
  [[ "$output" != *"old-thread"* ]]
  [[ "$output" != *"Retired"* ]]
}

@test "doctor --deep skips live (non-archived) Sessions and Projects — they are discovered via the lifecycle tier, not the wikilink graph or Agent Index/MOC" {
  mkdir -p "$OBS_JAY/Sessions/live-thread" "$OBS_JAY/Projects"
  cat >"$OBS_JAY/Sessions/live-thread/_index.md" <<'EOF'
---
thread: live-thread
status: active
updated: 2026-07-20 10:00
project: Demo
aliases: [live-thread]
---
# 🟢 live-thread

## Bookmark
doing stuff
EOF
  cat >"$OBS_JAY/Projects/Demo.md" <<'EOF'
---
type: project
status: active
---
# 🟢 Demo

## Sessions
- [[live-thread]] — testing (status: active)
EOF
  run "$OM" doctor --deep
  [[ "$output" != *"ORPHAN"* ]]
  [[ "$output" != *"UNINDEXED"* ]]
  [ "$status" -eq 0 ]
}

@test "doctor --deep UNINDEXED: a note absent from both the Agent Index and every MOC fires" {
  printf -- '---\nschema: 1\n---\n# Home\n<!-- AGENT-INDEX:START -->\n<!-- AGENT-INDEX:END -->\n' >"$OBS_JAY/Home.md"
  mkdir -p "$OBS_JAY/Notes"
  printf -- '# Unindexed Note\ncontent.\n' >"$OBS_JAY/Notes/Unindexed.md"
  run "$OM" doctor --deep
  [ "$status" -eq 2 ]
  [[ "$output" == *"UNINDEXED"* ]]
  [[ "$output" == *"Unindexed"* ]]
}

@test "doctor --deep UNINDEXED: does not fire on a note present in the Agent Index" {
  # flo registers first in this suite's fixture config, so it is PRIMARY — the
  # only vault the Agent-Index-membership branch is consulted for.
  mkdir -p "$OBS_FLO/Notes"
  printf -- '# Indexed Note\ncontent.\n' >"$OBS_FLO/Notes/Indexed.md"
  cat >"$OBS_FLO/Home.md" <<'EOF'
---
schema: 1
---
# Home
<!-- AGENT-INDEX:START -->
### Section
| [[Notes/Indexed]] | the summary |
<!-- AGENT-INDEX:END -->
EOF
  run "$OM" doctor --deep
  echo "$output" | grep -qE '^\s*\[UNINDEXED\]\s+Notes/Indexed(\.md)?\s*$' && exit 1
  true
}

@test "doctor --deep UNINDEXED: does not fire on a note linked from a MOC" {
  mkdir -p "$OBS_JAY/Notes" "$OBS_JAY/MOCs"
  printf -- '# Moc Note\ncontent.\n' >"$OBS_JAY/Notes/MocNote.md"
  printf -- '# MOC - Topic\nSee [[MocNote]].\n' >"$OBS_JAY/MOCs/MOC - Topic.md"
  run "$OM" doctor --deep
  echo "$output" | grep -qE '^\s*\[UNINDEXED\]\s+Notes/MocNote(\.md)?\s*$' && exit 1
  true
}

@test "doctor --deep is not run by base doctor (no ORPHAN/UNINDEXED without --deep)" {
  mkdir -p "$OBS_JAY/Notes"
  printf -- '# Lonely Note\nno one links here.\n' >"$OBS_JAY/Notes/Lonely.md"
  run "$OM" doctor
  [[ "$output" != *"ORPHAN"* ]]
  [[ "$output" != *"UNINDEXED"* ]]
}

# --- verify (A1: single-file verify-on-write) -----------------------------------

@test "verify exits 0 silently on a path outside any configured vault" {
  run "$OM" verify "$BATS_TEST_TMPDIR/not-a-vault-file.md"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "verify exits 0 silently on a real repo source file (non-markdown, non-vault)" {
  run "$OM" verify "$ROOT/vaultmem"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "verify exits 0 silently on a nonexistent path" {
  run "$OM" verify "$OBS_JAY/Sessions/does-not-exist/_index.md"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "verify exits 0 silently when no file argument is given" {
  run "$OM" verify
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "verify is clean (exit 0, silent) on a healthy session note" {
  write_healthy_session verify-good-thread
  run "$OM" verify "$OBS_JAY/Sessions/verify-good-thread/_index.md"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "verify fires the same NOALIAS schema lint doctor would, scoped to one file" {
  write_healthy_session verify-noalias-thread
  sed -i.bak '/^aliases:/d' "$OBS_JAY/Sessions/verify-noalias-thread/_index.md"
  run "$OM" verify "$OBS_JAY/Sessions/verify-noalias-thread/_index.md"
  [ "$status" -ne 0 ]
  [[ "$output" == *"NOALIAS"* ]]
  [[ "$output" == *"verify-noalias-thread"* ]]
}

@test "verify does not report an unrelated broken session elsewhere in the vault" {
  write_healthy_session verify-scope-good
  mkdir -p "$OBS_JAY/Sessions/verify-scope-bad"
  printf -- '---\nstatus: active\n---\n# verify-scope-bad\n' >"$OBS_JAY/Sessions/verify-scope-bad/_index.md"
  run "$OM" verify "$OBS_JAY/Sessions/verify-scope-good/_index.md"
  [ "$status" -eq 0 ]
  [[ "$output" != *"verify-scope-bad"* ]]
}

@test "verify flags a dangling wikilink in the given note" {
  mkdir -p "$OBS_JAY/Projects"
  cat >"$OBS_JAY/Projects/dangling-note.md" <<'EOF'
---
type: project
status: active
---
# dangling-note

See [[Nowhere At All]] for context.
EOF
  run "$OM" verify "$OBS_JAY/Projects/dangling-note.md"
  [ "$status" -ne 0 ]
  [[ "$output" == *"DANGLING"* ]]
  [[ "$output" == *"Nowhere At All"* ]]
}

@test "verify flags a project GLYPH-DESYNC scoped to that project note" {
  mkdir -p "$OBS_JAY/Projects"
  cat >"$OBS_JAY/Projects/Desynced.md" <<'EOF'
---
type: project
status: active
---
# 💤 Desynced
EOF
  run "$OM" verify "$OBS_JAY/Projects/Desynced.md"
  [ "$status" -ne 0 ]
  [[ "$output" == *"GLYPH-DESYNC"* ]]
}

# --- groom --dry-run (A5) --------------------------------------------------------

@test "groom --dry-run previews the would-move list without touching the filesystem" {
  mkdir -p "$OBS_JAY/Projects" "$OBS_JAY/Sessions/keep-me" "$OBS_JAY/Sessions/wrap-up"
  cat >"$OBS_JAY/Projects/proj.md" <<'EOF'
---
type: project
status: active
---
# proj
## Sessions
- [[keep-me]] — ongoing (status: active)
- [[wrap-up]] — shipped (status: done)
EOF
  printf -- '---\nproject: proj\nstatus: active\n---\n# keep-me\n' >"$OBS_JAY/Sessions/keep-me/_index.md"
  printf -- '---\nproject: proj\nstatus: done\n---\n# wrap-up\n' >"$OBS_JAY/Sessions/wrap-up/_index.md"

  # snapshot mtimes/content before, to prove --dry-run left everything untouched
  before_proj=$(cat "$OBS_JAY/Projects/proj.md")
  # whole-tree checksum: proves --dry-run writes NOTHING anywhere in the fixture
  # vault, not just the one file this test happens to inspect by name.
  before_tree=$(find "$OBS_JAY" -type f -exec shasum {} + | sort)

  run "$OM" -v jay groom --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"Sessions/wrap-up"* ]]
  [[ "$output" == *"Sessions/_archive/wrap-up"* ]]
  [[ "$output" == *"would flip"* ]]
  [[ "$output" == *"dry run"* ]]

  # no mv: both original session dirs still present, no _archive/ created
  [ -d "$OBS_JAY/Sessions/keep-me" ]
  [ -d "$OBS_JAY/Sessions/wrap-up" ]
  [ ! -e "$OBS_JAY/Sessions/_archive" ]
  # no write: project file byte-for-byte unchanged (status line NOT flipped)
  after_proj=$(cat "$OBS_JAY/Projects/proj.md")
  [ "$before_proj" = "$after_proj" ]
  grep -q '\[\[wrap-up\]\].*status: done)' "$OBS_JAY/Projects/proj.md"

  after_tree=$(find "$OBS_JAY" -type f -exec shasum {} + | sort)
  [ "$before_tree" = "$after_tree" ]
}

@test "groom --dry-run does not claim a flip for a Sessions line with no trailing status token" {
  # The `## Sessions` line links [[wrap-up]] but has no trailing
  # (active|parked|done) before its closing paren — _flip_project_status's
  # awk match requires that token, so real groom leaves this line untouched.
  # The --dry-run preview must not claim a flip it will not perform.
  mkdir -p "$OBS_JAY/Projects" "$OBS_JAY/Sessions/wrap-up"
  cat >"$OBS_JAY/Projects/proj.md" <<'EOF'
---
type: project
status: active
---
# proj
## Sessions
- [[wrap-up]] — shipped, no status token here
EOF
  printf -- '---\nproject: proj\nstatus: done\n---\n# wrap-up\n' >"$OBS_JAY/Sessions/wrap-up/_index.md"
  before_proj=$(cat "$OBS_JAY/Projects/proj.md")

  run "$OM" -v jay groom --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"Sessions/wrap-up"* ]]
  [[ "$output" != *"would flip"* ]]

  # confirm real groom agrees: the line is truly untouched by the mutation path
  run "$OM" -v jay groom
  [ "$status" -eq 0 ]
  after_proj=$(cat "$OBS_JAY/Projects/proj.md")
  [ "$before_proj" = "$after_proj" ]
}

@test "groom --dry-run claims a flip only for a Sessions line that carries the trailing status token" {
  mkdir -p "$OBS_JAY/Projects" "$OBS_JAY/Sessions/wrap-up"
  cat >"$OBS_JAY/Projects/proj.md" <<'EOF'
---
type: project
status: active
---
# proj
## Sessions
- [[wrap-up]] — shipped (status: done)
EOF
  printf -- '---\nproject: proj\nstatus: done\n---\n# wrap-up\n' >"$OBS_JAY/Sessions/wrap-up/_index.md"

  run "$OM" -v jay groom --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"would flip Projects/proj session line [[wrap-up]]"* ]]

  # confirm real groom agrees: the preview's promise matches the mutation
  run "$OM" -v jay groom
  [ "$status" -eq 0 ]
  grep -q '\[\[wrap-up\]\].*status: archived)' "$OBS_JAY/Projects/proj.md"
}

@test "groom --dry-run previews a done-project archive without moving it" {
  mkdir -p "$OBS_JAY/Projects" "$OBS_JAY/Sessions/_archive/old-thread"
  cat >"$OBS_JAY/Projects/finished.md" <<'EOF'
---
type: project
status: done
---
# finished
## Sessions
- [[old-thread]] — done (status: archived)
EOF
  run "$OM" -v jay groom --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"Projects/finished.md"* ]]
  [[ "$output" == *"Projects/_archive/finished.md"* ]]
  [ -f "$OBS_JAY/Projects/finished.md" ]
  [ ! -e "$OBS_JAY/Projects/_archive" ]
}

@test "groom --dry-run does not archive a project blocked by a live session (same as real groom)" {
  mkdir -p "$OBS_JAY/Projects" "$OBS_JAY/Sessions/live-one"
  cat >"$OBS_JAY/Projects/blocked.md" <<'EOF'
---
type: project
status: done
---
# blocked
## Sessions
- [[live-one]] — still going (status: active)
EOF
  printf -- '---\nproject: blocked\nstatus: active\n---\n# live-one\n' >"$OBS_JAY/Sessions/live-one/_index.md"
  run "$OM" -v jay groom --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"NOT archiving blocked"* ]]
  [ -f "$OBS_JAY/Projects/blocked.md" ]
}

@test "groom --dry-run reports 'Nothing to archive' just like real groom when nothing is due" {
  mkdir -p "$OBS_JAY/Sessions/active-one"
  printf -- '---\nstatus: active\nupdated: %s\n---\n# active-one\n' "$(days_ago 0)" >"$OBS_JAY/Sessions/active-one/_index.md"
  run "$OM" -v jay groom --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"Nothing to archive"* ]]
}

@test "real groom (no flag) still archives normally after --dry-run is introduced" {
  mkdir -p "$OBS_JAY/Projects" "$OBS_JAY/Sessions/wrap-up2"
  printf -- '---\nproject: proj2\nstatus: done\n---\n# wrap-up2\n' >"$OBS_JAY/Sessions/wrap-up2/_index.md"
  run "$OM" -v jay groom
  [ "$status" -eq 0 ]
  [ -d "$OBS_JAY/Sessions/_archive/wrap-up2" ]
  [ ! -e "$OBS_JAY/Sessions/wrap-up2" ]
}

# --- the backlog tier (Tasks/) ------------------------------------------------

# Seed a task. $1=vault root $2=slug $3=status $4=age-days $5=project $6=extra fm line
seed_task() {
  mkdir -p "$1/Tasks"
  {
    printf -- '---\ntype: task\nstatus: %s\n' "$3"
    [ -n "${5:-}" ] && printf 'project: %s\n' "$5"
    [ -n "${6:-}" ] && printf '%s\n' "$6"
    printf -- 'updated: %s\n---\n# Title of %s\n\nThe brief.\n' "$(days_ago "$4")" "$2"
  } >"$1/Tasks/$2.md"
}

@test "next lists ready tasks, 'next' status before 'backlog'" {
  seed_task "$OBS_JAY" later-item backlog 1
  seed_task "$OBS_JAY" queued-item next 1
  run "$OM" -v jay next
  [ "$status" -eq 0 ]
  # queued-item (next) must appear before later-item (backlog)
  [[ "$(echo "$output" | grep -n queued-item | cut -d: -f1)" -lt "$(echo "$output" | grep -n later-item | cut -d: -f1)" ]]
}

@test "next orders longest-waiting first within a status band" {
  seed_task "$OBS_JAY" fresh backlog 1
  seed_task "$OBS_JAY" ancient backlog 5
  run "$OM" -v jay next
  [ "$status" -eq 0 ]
  [[ "$(echo "$output" | grep -n ancient | cut -d: -f1)" -lt "$(echo "$output" | grep -n fresh | cut -d: -f1)" ]]
}

# Regression: `read` with IFS=$'\t' folds consecutive tabs into ONE delimiter, so
# an empty middle field (project / blocked_by) shifted every later field left and
# a task's TITLE was read as its blocked_by — making every unblocked task look
# blocked. _task_rows emits `-` for empty optional fields to prevent this.
@test "next treats a task with no project and no blocked_by as ready, not blocked" {
  seed_task "$OBS_JAY" bare backlog 1
  run "$OM" -v jay next
  [ "$status" -eq 0 ]
  [[ "$output" == *"Ready"* ]]
  [[ "$output" == *"bare"* ]]
  [[ "$output" != *"Nothing ready"* ]]
  # the title must not be reported as a blocker
  [[ "$output" != *"blocked by Title of bare"* ]]
}

@test "next separates blocked tasks out of the ready set" {
  seed_task "$OBS_JAY" upstream next 1
  seed_task "$OBS_JAY" downstream backlog 1 "" "blocked_by: upstream"
  run "$OM" -v jay next
  [ "$status" -eq 0 ]
  [[ "$output" == *"Blocked:"* ]]
  [[ "$output" == *"downstream — blocked by upstream"* ]]
}

@test "next hides active and done tasks (only backlog/next are ready)" {
  seed_task "$OBS_JAY" in-flight active 1 "" "session: in-flight"
  seed_task "$OBS_JAY" shipped done 1
  run "$OM" -v jay next
  [ "$status" -eq 0 ]
  [[ "$output" == *"No tasks yet"* ]]
}

@test "next caps rows with -n and reports how many were dropped" {
  seed_task "$OBS_JAY" t1 backlog 3
  seed_task "$OBS_JAY" t2 backlog 2
  seed_task "$OBS_JAY" t3 backlog 1
  run "$OM" -v jay -n 2 next
  [ "$status" -eq 0 ]
  [[ "$output" == *"1 more"* ]]
}

@test "next warns when a backlog task has gone stale" {
  seed_task "$OBS_JAY" forgotten backlog 40
  run "$OM" -v jay next
  [ "$status" -eq 0 ]
  [[ "$output" == *"untouched >"* ]]
}

@test "next says so plainly when there are no tasks at all" {
  run "$OM" -v jay next
  [ "$status" -eq 0 ]
  [[ "$output" == *"No tasks yet"* ]]
}

@test "task <slug> prints the facts and the body brief" {
  seed_task "$OBS_JAY" spec-me next 1 drs-v2 "linear: https://example.test/ISSUE-1"
  run "$OM" -v jay task spec-me
  [ "$status" -eq 0 ]
  [[ "$output" == *"status:  next"* ]]
  [[ "$output" == *"project: drs-v2"* ]]
  [[ "$output" == *"linear:  https://example.test/ISSUE-1"* ]]
  [[ "$output" == *"The brief."* ]]
  # frontmatter itself is not echoed back
  [[ "$output" != *"type: task"* ]]
}

@test "task <slug> fails with a clear message on an unknown slug" {
  run "$OM" -v jay task nope
  [ "$status" -ne 0 ]
  [[ "$output" == *"no task: nope"* ]]
}

@test "task --promote prints the conversion recipe without writing anything" {
  seed_task "$OBS_JAY" promote-me next 1 drs-v2
  run "$OM" -v jay task promote-me --promote
  [ "$status" -eq 0 ]
  [[ "$output" == *"thread: promote-me"* ]]
  [[ "$output" == *"project: drs-v2"* ]]
  [[ "$output" == *"aliases: [promote-me]"* ]]
  [[ "$output" == *"CONVERTED, not copied"* ]]
  # read-only: no session was created, task status untouched
  [ ! -e "$OBS_JAY/Sessions/promote-me" ]
  grep -q 'status: next' "$OBS_JAY/Tasks/promote-me.md"
}

@test "task --promote warns when the task is still blocked" {
  seed_task "$OBS_JAY" blocked-promote backlog 1 "" "blocked_by: something-else"
  run "$OM" -v jay task blocked-promote --promote
  [ "$status" -eq 0 ]
  [[ "$output" == *"blocked by something-else"* ]]
}

# --- task --promote --apply (mutating promotion) --------------------------

# Seed a minimal Project note with a ## Sessions heading, so --apply has
# somewhere to append the session index row.
seed_apply_project() { # $1=vault root $2=name (default drs-v2)
  local name="${2:-drs-v2}"
  mkdir -p "$1/Projects"
  cat >"$1/Projects/$name.md" <<EOF
---
type: project
status: active
repos: [ofp-drs]
---
# $name

## Sessions
- [[old-thread]] — something (status: done)

## Pinned
- a pinned constant
EOF
}

@test "task --promote (bare) is unchanged by the existence of --apply" {
  seed_apply_project "$OBS_JAY"
  seed_task "$OBS_JAY" promote-me next 1 drs-v2
  run "$OM" -v jay task promote-me --promote
  [ "$status" -eq 0 ]
  [[ "$output" == *"thread: promote-me"* ]]
  [[ "$output" == *"CONVERTED, not copied"* ]]
  [ ! -e "$OBS_JAY/Sessions/promote-me" ]
  grep -q 'status: next' "$OBS_JAY/Tasks/promote-me.md"
}

@test "task --promote --apply creates the session, updates the Project index, and flips the task" {
  seed_apply_project "$OBS_JAY"
  seed_task "$OBS_JAY" promote-me next 1 drs-v2
  run "$OM" -v jay task promote-me --promote --apply
  [ "$status" -eq 0 ]
  [[ "$output" == *"Promoted task"* ]]
  [[ "$output" == *"$OBS_JAY/Sessions/promote-me/_index.md"* ]]

  # 1) session note
  [ -f "$OBS_JAY/Sessions/promote-me/_index.md" ]
  grep -q 'thread: promote-me' "$OBS_JAY/Sessions/promote-me/_index.md"
  grep -q 'status: active' "$OBS_JAY/Sessions/promote-me/_index.md"
  grep -q 'aliases: \[promote-me\]' "$OBS_JAY/Sessions/promote-me/_index.md"
  grep -q 'task: promote-me' "$OBS_JAY/Sessions/promote-me/_index.md"
  grep -q '## Git state' "$OBS_JAY/Sessions/promote-me/_index.md"

  # 2) Project index — new row lands under ## Sessions, above older content
  run grep -n 'promote-me\|old-thread' "$OBS_JAY/Projects/drs-v2.md"
  local new_line old_line
  new_line=$(printf '%s\n' "$output" | grep 'promote-me' | cut -d: -f1)
  old_line=$(printf '%s\n' "$output" | grep 'old-thread' | cut -d: -f1)
  [ "$new_line" -lt "$old_line" ]

  # 3) task flips last
  grep -q 'status: active' "$OBS_JAY/Tasks/promote-me.md"
  grep -q 'session: promote-me' "$OBS_JAY/Tasks/promote-me.md"
}

@test "task --promote --apply refuses when Sessions/<slug>/ already exists, and writes nothing" {
  seed_apply_project "$OBS_JAY"
  seed_task "$OBS_JAY" taken next 1 drs-v2
  mkdir -p "$OBS_JAY/Sessions/taken"
  printf 'pre-existing\n' >"$OBS_JAY/Sessions/taken/marker.md"
  run "$OM" -v jay task taken --promote --apply
  [ "$status" -ne 0 ]
  [[ "$output" == *"already exists"* ]]
  # nothing else was written
  [ ! -f "$OBS_JAY/Sessions/taken/_index.md" ]
  [ -f "$OBS_JAY/Sessions/taken/marker.md" ]
  grep -q 'status: next' "$OBS_JAY/Tasks/taken.md"
  [[ "$(cat "$OBS_JAY/Projects/drs-v2.md")" != *"[[taken]]"* ]]
}

@test "task --promote --apply refuses when the task has no project: field" {
  seed_task "$OBS_JAY" orphan-task next 1
  run "$OM" -v jay task orphan-task --promote --apply
  [ "$status" -ne 0 ]
  [[ "$output" == *"no project"* ]]
  [ ! -e "$OBS_JAY/Sessions/orphan-task" ]
}

@test "task --promote --apply refuses when project: does not resolve to a Project note" {
  seed_task "$OBS_JAY" ghost-project next 1 nonexistent-project
  run "$OM" -v jay task ghost-project --promote --apply
  [ "$status" -ne 0 ]
  [[ "$output" == *"does not resolve"* ]]
  [ ! -e "$OBS_JAY/Sessions/ghost-project" ]
}

@test "task --promote --apply refuses when the task is blocked" {
  seed_apply_project "$OBS_JAY"
  seed_task "$OBS_JAY" still-blocked backlog 1 drs-v2 "blocked_by: something-else"
  run "$OM" -v jay task still-blocked --promote --apply
  [ "$status" -ne 0 ]
  [[ "$output" == *"blocked by something-else"* ]]
  [ ! -e "$OBS_JAY/Sessions/still-blocked" ]
}

@test "task --apply without --promote is a usage error" {
  seed_apply_project "$OBS_JAY"
  seed_task "$OBS_JAY" bare-apply next 1 drs-v2
  run "$OM" -v jay task bare-apply --apply
  [ "$status" -ne 0 ]
  [[ "$output" == *"usage:"* ]]
  [ ! -e "$OBS_JAY/Sessions/bare-apply" ]
}

@test "groom archives done tasks into Tasks/_archive/" {
  seed_task "$OBS_JAY" finished done 1
  run "$OM" -v jay groom
  [ "$status" -eq 0 ]
  [ -f "$OBS_JAY/Tasks/_archive/finished.md" ]
  [ ! -e "$OBS_JAY/Tasks/finished.md" ]
}

@test "groom --dry-run previews a task archive without moving it" {
  seed_task "$OBS_JAY" finished2 done 1
  run "$OM" -v jay groom --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"Tasks/finished2.md → Tasks/_archive/finished2.md"* ]]
  [ -f "$OBS_JAY/Tasks/finished2.md" ]
  [ ! -e "$OBS_JAY/Tasks/_archive/finished2.md" ]
}

@test "groom reports stale backlog separately from stale sessions" {
  seed_task "$OBS_JAY" rotting backlog 40
  run "$OM" -v jay groom
  [ "$status" -eq 0 ]
  [[ "$output" == *"Stale backlog"* ]]
  [[ "$output" == *"rotting"* ]]
}

@test "groom does not count a blocked task as stale backlog" {
  seed_task "$OBS_JAY" waiting backlog 40 "" "blocked_by: upstream-thing"
  seed_task "$OBS_JAY" upstream-thing next 1
  run "$OM" -v jay groom
  [ "$status" -eq 0 ]
  [[ "$output" != *"Stale backlog"* ]]
}

@test "archived tasks drop out of next" {
  mkdir -p "$OBS_JAY/Tasks/_archive"
  printf -- '---\ntype: task\nstatus: backlog\nupdated: %s\n---\n# archived one\n' "$(days_ago 1)" \
    >"$OBS_JAY/Tasks/_archive/gone.md"
  run "$OM" -v jay next
  [ "$status" -eq 0 ]
  [[ "$output" == *"No tasks yet"* ]]
}

@test "doctor flags a task status outside backlog|next|active|done" {
  seed_task "$OBS_JAY" wrong-status parked 1
  run "$OM" -v jay doctor
  [[ "$output" == *"TASK-STATUS"* ]]
  [[ "$output" == *"wrong-status"* ]]
}

@test "doctor flags a blocked_by pointing at a task that does not exist" {
  seed_task "$OBS_JAY" orphan-dep backlog 1 "" "blocked_by: ghost"
  run "$OM" -v jay doctor
  [[ "$output" == *"TASK-BLOCKED-DANGLING"* ]]
}

@test "doctor accepts a blocked_by pointing at an archived task" {
  mkdir -p "$OBS_JAY/Tasks/_archive"
  printf -- '---\ntype: task\nstatus: done\nupdated: %s\n---\n# done dep\n' "$(days_ago 1)" \
    >"$OBS_JAY/Tasks/_archive/landed.md"
  seed_task "$OBS_JAY" depends-on-landed backlog 1 "" "blocked_by: landed"
  run "$OM" -v jay doctor
  [[ "$output" != *"TASK-BLOCKED-DANGLING"* ]]
}

@test "doctor flags an active task with no session backlink" {
  seed_task "$OBS_JAY" promoted-nosession active 1
  run "$OM" -v jay doctor
  [[ "$output" == *"TASK-NO-SESSION"* ]]
}

@test "doctor flags a task missing required frontmatter" {
  mkdir -p "$OBS_JAY/Tasks"
  printf -- '---\ntype: task\n---\n# no status or updated\n' >"$OBS_JAY/Tasks/bare-fm.md"
  run "$OM" -v jay doctor
  [[ "$output" == *"MISSING-FM"* ]]
  [[ "$output" == *"bare-fm"* ]]
}

@test "init scaffolds Tasks/ and a Task template" {
  run "$OM" init --vault jay
  [ "$status" -eq 0 ]
  [ -d "$OBS_JAY/Tasks" ]
  [ -f "$OBS_JAY/Templates/Task.md" ]
  grep -q 'backlog | next | active | done' "$OBS_JAY/Templates/Task.md"
}

# The usage block is printed by a hardcoded `sed -n '4,Np'` line range, so adding
# usage lines without bumping N silently truncates the help output. Pin it.
@test "usage output ends with the final usage comment line" {
  run "$OM"
  [ "$status" -eq 0 ]
  [[ "$output" == *"planned → active → done"* ]]
}

@test "doctor --deep does not flag tasks as ORPHAN/UNINDEXED" {
  # Tasks are discovered through the lifecycle tier (next / task <slug>), never
  # through the wikilink graph, so requiring inbound links would be a false
  # positive on every schema-legal task.
  printf -- '---\nschema: 1\n---\n# Home\n<!-- AGENT-INDEX:START -->\n<!-- AGENT-INDEX:END -->\n' >"$OBS_JAY/Home.md"
  seed_task "$OBS_JAY" lonely backlog 1
  run "$OM" -v jay doctor --deep
  [[ "$output" != *"lonely"* ]]
}

# --- worktrees (query the ## Git state tables) -----------------------------

# Seed a session _index.md with a given ## Git state body (raw markdown after
# the heading, or "" for none at all). $3 status defaults to active.
seed_git_state_session() { # $1=vault root $2=thread $3=git-state-block $4=status
  mkdir -p "$1/Sessions/$2"
  {
    printf -- '---\nthread: %s\nproject: drs-v2\nstatus: %s\naliases: [%s]\nupdated: 2026-08-06 10:00\n---\n' \
      "$2" "${4:-active}" "$2"
    printf '# %s\n\n## Bookmark\nLast: x · Next: y\n' "$2"
    if [ -n "${3:-}" ]; then
      printf '\n## Git state\n%s\n' "$3"
    fi
  } >"$1/Sessions/$2/_index.md"
}

@test "worktrees <thread> prints the repo/branch/pr/state row from ## Git state" {
  seed_git_state_session "$OBS_JAY" has-wt '| Repo | Branch / worktree | PR | State |
|---|---|---|---|
| ofp-drs | `feature/x` (worktree: `~/src/x/ofp-drs-feature-x`) | #123 | open |'
  run "$OM" -v jay worktrees has-wt
  [ "$status" -eq 0 ]
  [[ "$output" == *"has-wt"* ]]
  [[ "$output" == *"ofp-drs"* ]]
  [[ "$output" == *"#123"* ]]
  [[ "$output" == *"open"* ]]
}

@test "worktrees <thread> reports nothing (exit 0) for a placeholder-only Git state row" {
  seed_git_state_session "$OBS_JAY" placeholder-only '(no worktree — design only)'
  run "$OM" -v jay worktrees placeholder-only
  [ "$status" -eq 0 ]
  [[ "$output" == *"no Git state rows"* ]]
}

@test "worktrees <thread> reports nothing (exit 0) when the session has no ## Git state heading at all" {
  seed_git_state_session "$OBS_JAY" no-heading ""
  run "$OM" -v jay worktrees no-heading
  [ "$status" -eq 0 ]
  [[ "$output" == *"no Git state rows"* ]]
}

@test "worktrees <thread> reports nothing (exit 0) for a Git state table with header+separator but no data rows" {
  seed_git_state_session "$OBS_JAY" empty-table '| Repo | Branch / worktree | PR | State |
|---|---|---|---|'
  run "$OM" -v jay worktrees empty-table
  [ "$status" -eq 0 ]
  [[ "$output" == *"no Git state rows"* ]]
}

@test "worktrees <thread> fails clearly on an unknown thread" {
  run "$OM" -v jay worktrees nope-thread
  [ "$status" -ne 0 ]
  [[ "$output" == *"no such session: nope-thread"* ]]
}

@test "worktrees with no thread lists every active session's row, skipping placeholder/tableless ones" {
  seed_git_state_session "$OBS_JAY" has-wt '| Repo | Branch / worktree | PR | State |
|---|---|---|---|
| ofp-drs | `feature/x` | #123 | open |'
  seed_git_state_session "$OBS_JAY" placeholder-only '(no worktree — design only)'
  seed_git_state_session "$OBS_JAY" no-heading ""
  run "$OM" -v jay worktrees
  [ "$status" -eq 0 ]
  [[ "$output" == *"has-wt"* ]]
  [[ "$output" != *"placeholder-only"* ]]
  [[ "$output" != *"no-heading"* ]]
}

@test "worktrees with no thread excludes parked/done sessions but a direct lookup still works" {
  seed_git_state_session "$OBS_JAY" parked-one '| Repo | Branch / worktree | PR | State |
|---|---|---|---|
| ofp-drs | `feature/parked` | - | idle |' parked
  run "$OM" -v jay worktrees
  [ "$status" -eq 0 ]
  [[ "$output" != *"parked-one"* ]]
  run "$OM" -v jay worktrees parked-one
  [ "$status" -eq 0 ]
  [[ "$output" == *"parked-one"* ]]
  [[ "$output" == *"idle"* ]]
}

@test "worktrees --format json emits {thread,repo,worktree,pr,state} objects" {
  seed_git_state_session "$OBS_JAY" has-wt '| Repo | Branch / worktree | PR | State |
|---|---|---|---|
| ofp-drs | `feature/x` | #123 | open |'
  run "$OM" -v jay worktrees has-wt --format json
  [ "$status" -eq 0 ]
  [[ "$output" == *'"thread":"has-wt"'* ]]
  [[ "$output" == *'"repo":"ofp-drs"'* ]]
  [[ "$output" == *'"pr":"#123"'* ]]
  [[ "$output" == *'"state":"open"'* ]]
}

@test "worktrees --format json prints [] for a placeholder-only session" {
  seed_git_state_session "$OBS_JAY" placeholder-only '(no worktree — design only)'
  run "$OM" -v jay worktrees placeholder-only --format json
  [ "$status" -eq 0 ]
  [[ "$output" == "[]" ]]
}

@test "worktrees rejects an unsupported --format value" {
  run "$OM" -v jay worktrees --format files
  [ "$status" -ne 0 ]
  [[ "$output" == *"--format wants cli|json"* ]]
}

# --- judge extension shim (core side) -------------------------------------------
# Core never runs the real extension here: every test points the resolver at a
# stub under $BATS_TEST_TMPDIR. `judge_isolate` also copies the script out of the
# repo, so the third resolution step (<script dir>/ext/) cannot find a real
# ext/judge/ in the tree.
judge_isolate() {
  export XDG_DATA_HOME="$BATS_TEST_TMPDIR/data"
  unset VAULTMEM_EXT_DIR
  mkdir -p "$BATS_TEST_TMPDIR/real"
  cp "$OM" "$BATS_TEST_TMPDIR/real/vaultmem"
  JOM="$BATS_TEST_TMPDIR/real/vaultmem"
}

# Stub extension at <dir>/judge/vaultmem-judge. It records that it ran, its
# args, its stdin (with STUB_STDIN=1), and the env core handed it, then exits with $3 (default 0).
judge_stub() { # $1 = ext dir, $2 = tag, $3 = exit code
  mkdir -p "$1/judge"
  cat >"$1/judge/vaultmem-judge" <<EOF
#!/usr/bin/env bash
{
  printf 'tag=%s\n' "$2"
  printf 'args=%s\n' "\$*"
  printf 'bin=%s\n' "\$VAULTMEM_BIN"
  printf 'config=%s\n' "\$VAULTMEM_CONFIG"
  # Read stdin only when a test pipes state in: an inherited, never-closed
  # stdin would otherwise hang the stub.
  if [ -n "\${STUB_STDIN:-}" ]; then printf 'stdin=%s\n' "\$(cat)"; fi
} >"$BATS_TEST_TMPDIR/stub.ran"
exit ${3:-0}
EOF
  chmod +x "$1/judge/vaultmem-judge"
}

judge_config_on() { # $1 = enabled value, $2 = jay's judge value
  cat >"$VAULTMEM_CONFIG" <<EOF
[ext.judge]
enabled = $1

[vault.flo]
path = "$OBS_FLO"

[vault.jay]
path = "$OBS_JAY"
judge = $2
EOF
}

@test "judge config prints the frozen format with defaults filled in" {
  judge_isolate
  export HOME="$BATS_TEST_TMPDIR/home"
  run "$JOM" judge config
  [ "$status" -eq 0 ]
  expected="ext.judge.enabled=false
ext.judge.model=typesafe-ai/jev
ext.judge.base_url=https://ai-gateway.vercel.sh
ext.judge.zdr=true
ext.judge.timeout_ms=1500
ext.judge.key_file=$BATS_TEST_TMPDIR/home/.config/vaultmem/ai-gateway.key
ext.judge.log=true
ext.judge.rerank=false
ext.judge.hook_judges=
vault.flo.judge=false
vault.jay.judge=false
vault.flo.label=Flo
vault.flo.description=
vault.jay.label=Personal
vault.jay.description="
  [ "$output" = "$expected" ]
}

@test "judge config reflects [ext.judge] keys and per-vault judge flags" {
  judge_isolate
  export HOME="$BATS_TEST_TMPDIR/home"
  cat >"$VAULTMEM_CONFIG" <<EOF
[ext.judge]
enabled = true
zdr = false                 # owner's plan refuses ZDR
timeout_ms = 900
key_file = "~/keys/gw.key"
hook_judges = "nudge,groom"
future_key = "kept"

[vault.flo]
path = "$OBS_FLO"
judge = false

[vault.jay]
label = "Personal"
description = "Home lab, dotfiles, side projects; never FloSports work"
path = "$OBS_JAY"
judge = true
EOF
  run "$JOM" judge config
  [ "$status" -eq 0 ]
  expected="ext.judge.enabled=true
ext.judge.model=typesafe-ai/jev
ext.judge.base_url=https://ai-gateway.vercel.sh
ext.judge.zdr=false
ext.judge.timeout_ms=900
ext.judge.key_file=$BATS_TEST_TMPDIR/home/keys/gw.key
ext.judge.log=true
ext.judge.rerank=false
ext.judge.hook_judges=nudge,groom
ext.judge.future_key=kept
vault.flo.judge=false
vault.jay.judge=true
vault.flo.label=flo
vault.flo.description=
vault.jay.label=Personal
vault.jay.description=Home lab, dotfiles, side projects; never FloSports work"
  [ "$output" = "$expected" ]
  # The extended config is inside the accepted subset.
  run "$JOM" doctor
  [[ "$output" != *"Config errors"* ]]
}

@test "judge config is answered by core: no config file, no vault, no extension" {
  judge_isolate
  export VAULTMEM_CONFIG="$BATS_TEST_TMPDIR/absent.toml"
  export XDG_CONFIG_HOME="$BATS_TEST_TMPDIR/xdg"
  unset OBS_FLO OBS_JAY VAULTMEM_VAULT
  run "$JOM" judge config
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "ext.judge.enabled=false" ]
  [ "${lines[8]}" = "ext.judge.hook_judges=" ]
  [ "${#lines[@]}" -eq 9 ]
  [[ "$output" != *"vault."* ]]
}

@test "judge config is never forwarded to an installed extension" {
  judge_isolate
  export VAULTMEM_EXT_DIR="$BATS_TEST_TMPDIR/extdir"
  judge_stub "$VAULTMEM_EXT_DIR" envdir
  run "$JOM" judge config
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "ext.judge.enabled=false" ]
  [ ! -e "$BATS_TEST_TMPDIR/stub.ran" ]
}

@test "doctor hard-errors on a non-boolean vault judge value" {
  cat >"$VAULTMEM_CONFIG" <<EOF
[vault.jay]
path = "$OBS_JAY"
judge = "true"
EOF
  run "$OM" doctor
  [ "$status" -ne 0 ]
  [[ "$output" == *'"judge" in [vault.jay] must be true or false'* ]]
  cat >"$VAULTMEM_CONFIG" <<EOF
[vault.jay]
path = "$OBS_JAY"
judge = 1
EOF
  run "$OM" doctor
  [ "$status" -ne 0 ]
  [[ "$output" == *"must be true or false"* ]]
}

@test "doctor hard-errors on a nested ext section" {
  cat >"$VAULTMEM_CONFIG" <<EOF
[vault.jay]
path = "$OBS_JAY"

[ext.judge.sub]
enabled = true
EOF
  run "$OM" doctor
  [ "$status" -ne 0 ]
  [[ "$output" == *"nested section [ext.judge.sub]"* ]]
}

@test "doctor hard-errors on a bare [ext] section" {
  cat >"$VAULTMEM_CONFIG" <<EOF
[vault.jay]
path = "$OBS_JAY"

[ext]
enabled = true
EOF
  run "$OM" doctor
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown or nested section [ext]"* ]]
}

@test "doctor hard-errors on malformed values in an ext section" {
  cat >"$VAULTMEM_CONFIG" <<EOF
[vault.jay]
path = "$OBS_JAY"

[ext.judge]
model = typesafe-ai/jev
hook_judges = ["nudge"]
EOF
  run "$OM" doctor
  [ "$status" -ne 0 ]
  [[ "$output" == *'unquoted string value for "model"'* ]]
  [[ "$output" == *'arrays/inline-tables not supported ("hook_judges")'* ]]
}

@test "doctor does not validate key names inside an ext section" {
  cat >"$VAULTMEM_CONFIG" <<EOF
[vault.jay]
path = "$OBS_JAY"

[ext.judge]
not_a_real_key = "fine"

[ext.other-ext]
whatever = 3
EOF
  run "$OM" doctor
  [[ "$output" != *"Config errors"* ]]
  [[ "$output" != *"unknown key"* ]]
}

@test "an [ext.*] section registers no vault" {
  judge_config_on true true
  run "$OM" vaults
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 2 ]
  [[ "$output" != *"ext"* ]]
}

@test "judge: not installed prints one stderr line and exits 3" {
  judge_isolate
  run "$JOM" judge list
  [ "$status" -eq 3 ]
  [ "${#lines[@]}" -eq 1 ]
  [[ "$output" == *'extension "judge" is not installed'* ]]
  # The line is on stderr; stdout stays empty.
  run bash -c '"$0" judge list 2>/dev/null' "$JOM"
  [ "$status" -eq 3 ]
  [ -z "$output" ]
}

@test "judge: never resolves the extension from PATH" {
  judge_isolate
  mkdir -p "$BATS_TEST_TMPDIR/pathbin"
  printf '#!/usr/bin/env bash\ntouch "%s/path.ran"\n' "$BATS_TEST_TMPDIR" >"$BATS_TEST_TMPDIR/pathbin/vaultmem-judge"
  chmod +x "$BATS_TEST_TMPDIR/pathbin/vaultmem-judge"
  PATH="$BATS_TEST_TMPDIR/pathbin:$PATH" run "$JOM" judge list
  [ "$status" -eq 3 ]
  [ ! -e "$BATS_TEST_TMPDIR/path.ran" ]
}

@test "judge: resolution order is VAULTMEM_EXT_DIR, then XDG data dir, then the script dir" {
  judge_isolate
  judge_stub "$BATS_TEST_TMPDIR/real/ext" scriptdir
  run "$JOM" judge list
  [ "$status" -eq 0 ]
  grep -qx 'tag=scriptdir' "$BATS_TEST_TMPDIR/stub.ran"

  judge_stub "$XDG_DATA_HOME/vaultmem/ext" xdg
  run "$JOM" judge list
  grep -qx 'tag=xdg' "$BATS_TEST_TMPDIR/stub.ran"

  export VAULTMEM_EXT_DIR="$BATS_TEST_TMPDIR/extdir"
  judge_stub "$VAULTMEM_EXT_DIR" envdir
  run "$JOM" judge list
  grep -qx 'tag=envdir' "$BATS_TEST_TMPDIR/stub.ran"

  # A VAULTMEM_EXT_DIR without the extension falls through to the next step.
  export VAULTMEM_EXT_DIR="$BATS_TEST_TMPDIR/empty"
  run "$JOM" judge list
  grep -qx 'tag=xdg' "$BATS_TEST_TMPDIR/stub.ran"
}

@test "judge: the script-dir step resolves symlinks, and VAULTMEM_BIN is the real absolute path" {
  judge_isolate
  judge_stub "$BATS_TEST_TMPDIR/real/ext" scriptdir
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  ln -s ../real/vaultmem "$BATS_TEST_TMPDIR/bin/vaultmem"
  run "$BATS_TEST_TMPDIR/bin/vaultmem" judge list
  [ "$status" -eq 0 ]
  grep -qx 'tag=scriptdir' "$BATS_TEST_TMPDIR/stub.ran"
  real="$(cd -P "$BATS_TEST_TMPDIR/real" && pwd)/vaultmem"
  grep -qx "bin=$real" "$BATS_TEST_TMPDIR/stub.ran"
  grep -qx "config=$VAULTMEM_CONFIG" "$BATS_TEST_TMPDIR/stub.ran"
}

@test "judge: args after the subcommand reach the extension verbatim, with stdin and its exit code" {
  judge_isolate
  export VAULTMEM_EXT_DIR="$BATS_TEST_TMPDIR/extdir"
  judge_stub "$VAULTMEM_EXT_DIR" envdir 2
  # --vault / --format / -n / -h are core flags everywhere else; after `judge`
  # they belong to the extension.
  STUB_STDIN=1 run bash -c 'printf "the state" | "$0" judge groom-triage --vault jay --format json -n 5 -h' "$JOM"
  [ "$status" -eq 2 ]
  grep -qx 'args=groom-triage --vault jay --format json -n 5 -h' "$BATS_TEST_TMPDIR/stub.ran"
  grep -qx 'stdin=the state' "$BATS_TEST_TMPDIR/stub.ran"
}

@test "judge: runs the extension with no vault configured (the extension decides)" {
  judge_isolate
  export VAULTMEM_EXT_DIR="$BATS_TEST_TMPDIR/extdir"
  judge_stub "$VAULTMEM_EXT_DIR" envdir 3
  export VAULTMEM_CONFIG="$BATS_TEST_TMPDIR/absent.toml"
  export XDG_CONFIG_HOME="$BATS_TEST_TMPDIR/xdg"
  unset OBS_FLO OBS_JAY VAULTMEM_VAULT
  run "$JOM" judge doctor
  [ "$status" -eq 3 ]
  [[ "$output" != *"no vault configured"* ]]
  [ -e "$BATS_TEST_TMPDIR/stub.ran" ]
}

@test "_judge returns 3 without running the extension when [ext.judge] is disabled" {
  judge_isolate
  export VAULTMEM_EXT_DIR="$BATS_TEST_TMPDIR/extdir"
  judge_stub "$VAULTMEM_EXT_DIR" envdir
  judge_config_on false true
  run bash -c 'printf state | "$0" _judge nudge jay' "$JOM"
  [ "$status" -eq 3 ]
  [ -z "$output" ]
  [ ! -e "$BATS_TEST_TMPDIR/stub.ran" ]
  # Absent [ext.judge] is the same as disabled.
  printf '[vault.jay]\npath = "%s"\njudge = true\n' "$OBS_JAY" >"$VAULTMEM_CONFIG"
  run bash -c 'printf state | "$0" _judge nudge jay' "$JOM"
  [ "$status" -eq 3 ]
  [ ! -e "$BATS_TEST_TMPDIR/stub.ran" ]
}

@test "_judge returns 3 without running the extension for a vault without judge = true" {
  judge_isolate
  export VAULTMEM_EXT_DIR="$BATS_TEST_TMPDIR/extdir"
  judge_stub "$VAULTMEM_EXT_DIR" envdir
  judge_config_on true true
  for v in flo nosuch ""; do
    run bash -c 'printf state | "$0" _judge nudge "$1"' "$JOM" "$v"
    [ "$status" -eq 3 ]
    [ ! -e "$BATS_TEST_TMPDIR/stub.ran" ]
  done
}

@test "_judge runs the extension with --vault <id> and state on stdin when enabled" {
  judge_isolate
  export VAULTMEM_EXT_DIR="$BATS_TEST_TMPDIR/extdir"
  judge_stub "$VAULTMEM_EXT_DIR" envdir 1
  judge_config_on true true
  STUB_STDIN=1 run bash -c 'printf "session text" | "$0" _judge nudge jay --gate work_happened' "$JOM"
  [ "$status" -eq 1 ]
  grep -qx 'args=nudge --vault jay --gate work_happened' "$BATS_TEST_TMPDIR/stub.ran"
  grep -qx 'stdin=session text' "$BATS_TEST_TMPDIR/stub.ran"
}

@test "_judge returns 3 when enabled but the extension is not installed" {
  judge_isolate
  judge_config_on true true
  run bash -c 'printf state | "$0" _judge nudge jay 2>/dev/null' "$JOM"
  [ "$status" -eq 3 ]
  [ -z "$output" ]
}

@test "usage documents the judge subcommand" {
  run "$OM" -h
  [ "$status" -eq 0 ]
  [[ "$output" == *"vaultmem judge config"* ]]
  [[ "$output" == *"vaultmem judge calibration"* ]]
  [[ "$output" == *"planned → active → done"* ]]
}

@test "install.sh --ext skips cleanly when the extension is not in the tree" {
  mkdir -p "$BATS_TEST_TMPDIR/rel"
  cp "$ROOT/install.sh" "$ROOT/vaultmem" "$BATS_TEST_TMPDIR/rel/"
  XDG_DATA_HOME="$BATS_TEST_TMPDIR/data" run "$BATS_TEST_TMPDIR/rel/install.sh" --prefix "$BATS_TEST_TMPDIR/prefix" --ext judge
  [ "$status" -eq 0 ]
  [[ "$output" == *"no ext/judge directory"* ]]
  [ ! -e "$BATS_TEST_TMPDIR/data/vaultmem/ext/judge" ]
}

@test "install.sh --ext links the extension where vaultmem resolves it" {
  mkdir -p "$BATS_TEST_TMPDIR/rel"
  cp "$ROOT/install.sh" "$ROOT/vaultmem" "$BATS_TEST_TMPDIR/rel/"
  judge_stub "$BATS_TEST_TMPDIR/rel/ext" shipped
  export XDG_DATA_HOME="$BATS_TEST_TMPDIR/data"
  run "$BATS_TEST_TMPDIR/rel/install.sh" --prefix "$BATS_TEST_TMPDIR/prefix" --ext judge
  [ "$status" -eq 0 ]
  [ -L "$XDG_DATA_HOME/vaultmem/ext/judge" ]
  # The installed copy has no ext/ beside it, so this resolves through XDG.
  run "$BATS_TEST_TMPDIR/prefix/bin/vaultmem" judge list
  [ "$status" -eq 0 ]
  grep -qx 'tag=shipped' "$BATS_TEST_TMPDIR/stub.ran"
}

@test "install.sh --ext rejects a path-like extension name" {
  mkdir -p "$BATS_TEST_TMPDIR/rel"
  cp "$ROOT/install.sh" "$ROOT/vaultmem" "$BATS_TEST_TMPDIR/rel/"
  XDG_DATA_HOME="$BATS_TEST_TMPDIR/data" run "$BATS_TEST_TMPDIR/rel/install.sh" --prefix "$BATS_TEST_TMPDIR/prefix" --ext ../judge
  [ "$status" -eq 2 ]
}

# --- groom --judge (core side) ---------------------------------------------------
# Every test here runs against a stub extension under $BATS_TEST_TMPDIR printing
# canned groom-triage JSON. The real extension is never invoked and nothing calls
# curl: `judge_isolate` also moves the script out of the repo so the script-dir
# resolution step cannot reach a real ext/judge/.

# A stub that answers with the caller-supplied JSON ($2) and records that it ran,
# with its args and the state it was handed.
groom_judge_stub() { # $1 = ext dir, $2 = response JSON, $3 = exit code
  mkdir -p "$1/judge"
  cat >"$1/judge/vaultmem-judge" <<EOF
#!/usr/bin/env bash
{
  printf 'args=%s\n' "\$*"
  printf 'state<<\n%s\n>>state\n' "\$(cat)"
} >>"$BATS_TEST_TMPDIR/stub.ran"
printf '%s\n' '$2'
exit ${3:-0}
EOF
  chmod +x "$1/judge/vaultmem-judge"
}

# `days_ago N` stamps exactly N*86400 seconds back, truncated to the minute, so
# the age floor lands on N only while the test runs inside that same minute: a
# second of drift makes it N-1. Tests that assert on the printed age use this
# instead, which backs off a further 6 hours and stays on N all day.
days_ago_stable() {
  if date -v-1d >/dev/null 2>&1; then
    date -v-"$1"d -v-6H +"%Y-%m-%d %H:%M"
  else date -d "$1 days ago 6 hours ago" +"%Y-%m-%d %H:%M"; fi
}

# One cold-parked session with the sections groom --judge sends, plus its Project.
groom_judge_fixture() {
  mkdir -p "$OBS_JAY/Sessions/cold-one" "$OBS_JAY/Projects"
  printf -- '---\nstatus: parked\nproject: p\nupdated: %s\n---\n# cold-one\n\n## Bookmark\nnext: land the parser\n\n## Pinned\n- a pin\n\n## Git state\n| repo | branch | pr | state |\n| r | b | 1 | open |\n' \
    "$(days_ago_stable 40)" >"$OBS_JAY/Sessions/cold-one/_index.md"
  printf -- '---\ntype: project\nstatus: active\n---\n# p\n\n## Decisions\n- chose the awk scanner\n' >"$OBS_JAY/Projects/p.md"
}

# Registry with the judge enabled and jay's consent set by the caller.
groom_judge_config() { # $1 = jay's judge value
  cat >"$VAULTMEM_CONFIG" <<EOF
[ext.judge]
enabled = true

[vault.jay]
label = "Personal"
path = "$OBS_JAY"
judge = $1
EOF
}

GROOM_JUDGE_OK='{"id":"20260922T101500Z-4f2a","judge":"groom-triage","answers":{"work_complete":{"probability":0.93},"has_next_step":{"probability":0.05},"blocked_external":{"probability":0.02},"undistilled":{"probability":0.91},"recommendation":{"choice":"archive","probabilities":{"archive":0.88,"park":0.07,"keep-active":0.03,"needs-human":0.02}}}}'

@test "groom --judge annotates a flagged row with the choice, probability, flags and log id" {
  judge_isolate
  groom_judge_fixture
  groom_judge_config true
  export VAULTMEM_EXT_DIR="$BATS_TEST_TMPDIR/extdir"
  groom_judge_stub "$VAULTMEM_EXT_DIR" "$GROOM_JUDGE_OK"
  run "$JOM" -v jay groom --judge
  [ "$status" -eq 0 ]
  [[ "$output" == *"cold-one (40d, p)  → archive 0.88 · work_complete, undistilled [20260922T101500Z-4f2a]"* ]]
  # Only the two booleans at or above 0.85 are flagged.
  [[ "$output" != *"has_next_step"* ]]
  [[ "$output" != *"blocked_external"* ]]
}

@test "groom --judge prints → ? when the top choice is below the confidence floor" {
  judge_isolate
  groom_judge_fixture
  groom_judge_config true
  export VAULTMEM_EXT_DIR="$BATS_TEST_TMPDIR/extdir"
  groom_judge_stub "$VAULTMEM_EXT_DIR" \
    '{"id":"low-1","answers":{"work_complete":{"probability":0.9},"recommendation":{"choice":"needs-human","probabilities":{"needs-human":0.42}}}}'
  run "$JOM" -v jay groom --judge
  [ "$status" -eq 0 ]
  [[ "$output" == *"cold-one (40d, p)  → ? [low-1]"* ]]
  # Below the floor the choice itself is withheld, flags and all.
  [[ "$output" != *"needs-human 0.42"* ]]
}

@test "groom --judge leaves the row exactly as today when the judge has no opinion" {
  judge_isolate
  groom_judge_fixture
  groom_judge_config true
  export VAULTMEM_EXT_DIR="$BATS_TEST_TMPDIR/extdir"
  groom_judge_stub "$VAULTMEM_EXT_DIR" '' 3
  run "$JOM" -v jay groom --judge
  [ "$status" -eq 0 ]
  [[ "$output" == *"  Personal: cold-one (40d, p)"* ]]
  [[ "$output" != *"→"* ]]
}

@test "groom --judge sends the design 8.1 state and the --subject the extension expects" {
  judge_isolate
  groom_judge_fixture
  groom_judge_config true
  export VAULTMEM_EXT_DIR="$BATS_TEST_TMPDIR/extdir"
  groom_judge_stub "$VAULTMEM_EXT_DIR" "$GROOM_JUDGE_OK"
  run "$JOM" -v jay groom --judge
  [ "$status" -eq 0 ]
  local ran="$BATS_TEST_TMPDIR/stub.ran"
  grep -q -- '--vault jay' "$ran"
  grep -q -- "--subject Sessions/cold-one/_index.md" "$ran"
  grep -q 'groom-triage' "$ran"
  # Deterministic facts are computed in bash and handed over as text.
  grep -qx 'Days since last update: 40' "$ran"
  grep -qx 'Flagged as: cold-parked' "$ran"
  grep -q '^Note length in lines: [0-9]' "$ran"
  # The sections design 8.1 lists.
  grep -qx '## Bookmark' "$ran"
  grep -qx '## Pinned' "$ran"
  grep -qx '## Git state' "$ran"
  grep -q 'next: land the parser' "$ran"
  grep -q 'chose the awk scanner' "$ran"
}

@test "groom --judge --dry-run prints the same judged report and moves nothing" {
  judge_isolate
  groom_judge_fixture
  groom_judge_config true
  mkdir -p "$OBS_JAY/Sessions/done-one"
  printf -- '---\nstatus: done\n---\n# done-one\n' >"$OBS_JAY/Sessions/done-one/_index.md"
  export VAULTMEM_EXT_DIR="$BATS_TEST_TMPDIR/extdir"
  groom_judge_stub "$VAULTMEM_EXT_DIR" "$GROOM_JUDGE_OK"
  run "$JOM" -v jay groom --judge --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"→ archive 0.88 · work_complete, undistilled"* ]]
  [[ "$output" == *"(dry run"* ]]
  # The done session is still in place: the judged path never writes.
  [ -f "$OBS_JAY/Sessions/done-one/_index.md" ]
  [ ! -d "$OBS_JAY/Sessions/_archive/done-one" ]
}

@test "groom --judge --format json carries the row facts and the answers verbatim" {
  judge_isolate
  groom_judge_fixture
  groom_judge_config true
  export VAULTMEM_EXT_DIR="$BATS_TEST_TMPDIR/extdir"
  groom_judge_stub "$VAULTMEM_EXT_DIR" "$GROOM_JUDGE_OK"
  run "$JOM" -v jay groom --judge --format json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '
    length == 1
    and .[0].vault == "jay"
    and .[0].session == "cold-one"
    and .[0].status == "cold-parked"
    and .[0].age_days == 40
    and (.[0].lines | type) == "number"
    and .[0].judge.id == "20260922T101500Z-4f2a"
    and .[0].judge.answers.recommendation.choice == "archive"
    and .[0].judge.answers.recommendation.probabilities.archive == 0.88
    and .[0].judge.answers.undistilled.probability == 0.91
  '
}

@test "groom --judge --format json reports a stale-active session with judge null on no opinion" {
  judge_isolate
  mkdir -p "$OBS_JAY/Sessions/stale-one"
  printf -- '---\nstatus: active\nupdated: %s\n---\n# stale-one\n' "$(days_ago_stable 10)" >"$OBS_JAY/Sessions/stale-one/_index.md"
  groom_judge_config true
  export VAULTMEM_EXT_DIR="$BATS_TEST_TMPDIR/extdir"
  groom_judge_stub "$VAULTMEM_EXT_DIR" '' 3
  run "$JOM" -v jay groom --judge --format json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '
    length == 1
    and .[0].session == "stale-one"
    and .[0].status == "stale-active"
    and .[0].age_days == 10
    and .[0].judge == null
  '
}

@test "groom --judge never assembles state for a vault that has not consented" {
  judge_isolate
  groom_judge_fixture
  groom_judge_config false
  export VAULTMEM_EXT_DIR="$BATS_TEST_TMPDIR/extdir"
  groom_judge_stub "$VAULTMEM_EXT_DIR" "$GROOM_JUDGE_OK"
  run "$JOM" -v jay groom --judge
  [ "$status" -eq 0 ]
  # The row prints as today and the extension was never executed.
  [[ "$output" == *"  Personal: cold-one (40d, p)"* ]]
  [[ "$output" != *"→"* ]]
  [ ! -e "$BATS_TEST_TMPDIR/stub.ran" ]
}

@test "groom without --judge is byte-identical with and without the extension installed" {
  judge_isolate
  groom_judge_fixture
  mkdir -p "$OBS_JAY/Sessions/stale-one"
  printf -- '---\nstatus: active\nupdated: %s\n---\n# stale-one\n' "$(days_ago_stable 10)" >"$OBS_JAY/Sessions/stale-one/_index.md"
  groom_judge_config true
  export VAULTMEM_EXT_DIR="$BATS_TEST_TMPDIR/extdir"
  groom_judge_stub "$VAULTMEM_EXT_DIR" "$GROOM_JUDGE_OK"
  run "$JOM" -v jay groom
  local with_status="$status" with_out="$output"
  # Same run with nothing installed anywhere the resolver looks.
  export VAULTMEM_EXT_DIR="$BATS_TEST_TMPDIR/empty"
  run "$JOM" -v jay groom
  [ "$status" -eq "$with_status" ]
  [ "$output" = "$with_out" ]
  # And the extension stayed untouched on the plain path.
  [ ! -e "$BATS_TEST_TMPDIR/stub.ran" ]
}

@test "groom --judge is inert when [ext.judge] is disabled" {
  judge_isolate
  groom_judge_fixture
  cat >"$VAULTMEM_CONFIG" <<EOF
[ext.judge]
enabled = false

[vault.jay]
label = "Personal"
path = "$OBS_JAY"
judge = true
EOF
  export VAULTMEM_EXT_DIR="$BATS_TEST_TMPDIR/extdir"
  groom_judge_stub "$VAULTMEM_EXT_DIR" "$GROOM_JUDGE_OK"
  run "$JOM" -v jay groom --judge
  [ "$status" -eq 0 ]
  [[ "$output" == *"  Personal: cold-one (40d, p)"* ]]
  [[ "$output" != *"→"* ]]
  [ ! -e "$BATS_TEST_TMPDIR/stub.ran" ]
}

@test "groom --judge judges each flagged session once, across both report sections" {
  judge_isolate
  groom_judge_fixture
  mkdir -p "$OBS_JAY/Sessions/stale-one"
  printf -- '---\nstatus: active\nupdated: %s\n---\n# stale-one\n' "$(days_ago_stable 10)" >"$OBS_JAY/Sessions/stale-one/_index.md"
  groom_judge_config true
  export VAULTMEM_EXT_DIR="$BATS_TEST_TMPDIR/extdir"
  groom_judge_stub "$VAULTMEM_EXT_DIR" "$GROOM_JUDGE_OK"
  run "$JOM" -v jay groom --judge
  [ "$status" -eq 0 ]
  # Both sections carry a column, and the stub ran exactly twice.
  [[ "$output" == *"cold-one (40d, p)  → archive"* ]]
  [[ "$output" == *"stale-one (10d, no project)  → archive"* ]]
  [ "$(grep -c '^args=' "$BATS_TEST_TMPDIR/stub.ran")" -eq 2 ]
}

@test "groom --judge does not annotate checkpoint-due or stale-backlog rows" {
  judge_isolate
  mkdir -p "$OBS_JAY/Sessions/fat-one"
  {
    printf -- '---\nstatus: active\nupdated: %s\n---\n# fat-one\n' "$(days_ago_stable 1)"
    i=0
    while [ "$i" -lt 200 ]; do
      printf 'line %s\n' "$i"
      i=$((i + 1))
    done
  } >"$OBS_JAY/Sessions/fat-one/_index.md"
  groom_judge_config true
  export VAULTMEM_EXT_DIR="$BATS_TEST_TMPDIR/extdir"
  groom_judge_stub "$VAULTMEM_EXT_DIR" "$GROOM_JUDGE_OK"
  run "$JOM" -v jay groom --judge
  [ "$status" -eq 0 ]
  # Fresh and only bloated: flagged for a checkpoint, never judged (8.1 covers
  # cold-parked and stale-active only).
  [[ "$output" == *"Checkpoint due"* ]]
  [[ "$output" != *"→"* ]]
  [ ! -e "$BATS_TEST_TMPDIR/stub.ran" ]
}

@test "groom --judge parses the gateway answer shape, with its type fields" {
  judge_isolate
  groom_judge_fixture
  groom_judge_config true
  export VAULTMEM_EXT_DIR="$BATS_TEST_TMPDIR/extdir"
  # The extension emits {id, judge, answers} where answers is the gateway object
  # verbatim, so every answer carries a "type" and a choice answer also carries
  # "confidence". A scanner that matches `"choice"` anywhere rather than only
  # where it is a key reads `"type":"choice"` instead and loses the choice.
  groom_judge_stub "$VAULTMEM_EXT_DIR" \
    '{"id":"gw-1","judge":"groom-triage","answers":{"work_complete":{"type":"boolean","probability":0.04},"has_next_step":{"type":"boolean","probability":0.93},"blocked_external":{"type":"boolean","probability":0.88},"undistilled":{"type":"boolean","probability":0.91},"recommendation":{"type":"choice","choice":"park","probabilities":{"archive":0.02,"park":0.81,"keep-active":0.13,"needs-human":0.04},"confidence":0.81}}}'
  run "$JOM" -v jay groom --judge
  [ "$status" -eq 0 ]
  [[ "$output" == *"→ park 0.81 · has_next_step, blocked_external, undistilled [gw-1]"* ]]
  # 0.04 is below the flag threshold, so the flag list must not carry it.
  [[ "$output" != *"work_complete"* ]]
}

@test "usage documents groom --judge" {
  run "$OM"
  [ "$status" -eq 0 ]
  [[ "$output" == *"vaultmem groom --judge"* ]]
}

@test "judge config skips label and description lines for a pathless vault" {
  judge_isolate
  cat >"$VAULTMEM_CONFIG" <<EOF
[vault.ghost]
label = "Ghost"
description = "no path yet"

[vault.jay]
path = "$OBS_JAY"
description = "Personal notes"
EOF
  run "$JOM" judge config
  [ "$status" -eq 0 ]
  [[ "$output" != *"vault.ghost."* ]]
  [ "${lines[$((${#lines[@]} - 2))]}" = "vault.jay.label=jay" ]
  [ "${lines[$((${#lines[@]} - 1))]}" = "vault.jay.description=Personal notes" ]
}

@test "doctor accepts a quoted vault description" {
  cat >"$VAULTMEM_CONFIG" <<EOF
[vault.jay]
path = "$OBS_JAY"
description = "Personal: dotfiles, homelab, side projects"
EOF
  run "$OM" doctor
  [[ "$output" != *"Config errors"* ]]
  [[ "$output" != *"description"* ]]
}

@test "doctor hard-errors on a vault description that is not a quoted string" {
  for bad in 'true' '42' 'personal-notes' '["a", "b"]'; do
    cat >"$VAULTMEM_CONFIG" <<EOF
[vault.jay]
path = "$OBS_JAY"
description = $bad
EOF
    run "$OM" doctor
    [ "$status" -ne 0 ]
    [[ "$output" == *'"description" in [vault.jay] must be a quoted string'* ]]
  done
}

# --- nudge --judge (judge design 8.2) -------------------------------------------
# A consenting, confidently-routed vault: flo claims $DEV_DIR/github.com/flocasts/**
# and has judge = true; nudge is named in hook_judges. Each test runs from a repo
# dir inside that glob. The stub extension records its args and stdin and prints
# $BATS_TEST_TMPDIR/stub.out, exiting with $STUB_RC (default 0).
nudge_judge_setup() { # $1 = hook_judges value, $2 = flo's judge value
  judge_isolate
  export VAULTMEM_EXT_DIR="$BATS_TEST_TMPDIR/extdir"
  mkdir -p "$VAULTMEM_EXT_DIR/judge"
  cat >"$VAULTMEM_EXT_DIR/judge/vaultmem-judge" <<EOF
#!/usr/bin/env bash
printf 'args=%s\n' "\$*" >"$BATS_TEST_TMPDIR/stub.ran"
cat >"$BATS_TEST_TMPDIR/stub.stdin"
cat "$BATS_TEST_TMPDIR/stub.out" 2>/dev/null
exit \${STUB_RC:-0}
EOF
  chmod +x "$VAULTMEM_EXT_DIR/judge/vaultmem-judge"
  cat >"$VAULTMEM_CONFIG" <<EOF
[ext.judge]
enabled = true
hook_judges = "${1-groom, nudge}"

[vault.flo]
label = "Flo"
path = "$OBS_FLO"
match_paths = "$DEV_DIR/github.com/flocasts/**"
judge = ${2:-true}

[vault.jay]
path = "$OBS_JAY"
judge = true
EOF
  printf -- '---\nschema: 1\n---\n# Home\n<!-- AGENT-INDEX:START -->\n<!-- AGENT-INDEX:END -->\n' >"$OBS_FLO/Home.md"
  mkdir -p "$OBS_FLO/Sessions/live" "$OBS_FLO/Projects"
  printf -- '---\nstatus: active\n---\n# live\n' >"$OBS_FLO/Sessions/live/_index.md"
  printf -- '---\ntype: project\nstatus: active\n---\n# Notes\n' >"$OBS_FLO/Projects/Notes.md"
  find "$OBS_FLO" "$OBS_JAY" -type f -exec touch -t 202001010000 {} +
  mkdir -p "$XDG_CACHE_HOME/vaultmem" "$DEV_DIR/github.com/flocasts/app"
  touch "$XDG_CACHE_HOME/vaultmem/nudge-stamp"
  # A Claude Code transcript: plain-string and array user turns, an assistant
  # text turn, and lines that must never reach the judge (a tool result, a
  # subagent sidechain turn, a meta line, thinking, a tool_use).
  TRANSCRIPT="$BATS_TEST_TMPDIR/transcript.jsonl"
  cat >"$TRANSCRIPT" <<'EOF'
{"type":"summary","summary":"old"}
{"parentUuid":null,"isSidechain":false,"type":"user","message":{"role":"user","content":"why does the cache thrash?"},"uuid":"u1"}
{"parentUuid":"u1","isSidechain":false,"type":"assistant","message":{"role":"assistant","content":[{"type":"thinking","thinking":"SECRET-THOUGHT"},{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"ls"}}]},"uuid":"a1"}
{"parentUuid":"a1","isSidechain":false,"type":"user","message":{"role":"user","content":[{"tool_use_id":"t1","type":"tool_result","content":"TOOL-OUTPUT"}]},"uuid":"u2"}
{"parentUuid":"u2","isSidechain":true,"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"SUBAGENT-TEXT"}]},"uuid":"s1"}
{"parentUuid":"u2","isSidechain":false,"isMeta":true,"type":"user","message":{"role":"user","content":"META-CAVEAT"},"uuid":"m1"}
{"parentUuid":"u2","isSidechain":false,"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Root cause: the \"eviction\" TTL was 0.\nFixed it."}]},"uuid":"a2"}
{"parentUuid":"a2","isSidechain":false,"type":"user","message":{"role":"user","content":[{"type":"text","text":"great, thanks"}]},"uuid":"u3"}
EOF
  HOOK_JSON="{\"session_id\":\"s\",\"transcript_path\":\"$TRANSCRIPT\",\"cwd\":\"$DEV_DIR/github.com/flocasts/app\",\"hook_event_name\":\"Stop\",\"stop_hook_active\":false}"
  cat >"$BATS_TEST_TMPDIR/stub.out" <<'EOF'
{"id":"j-7","judge":"capture-worthy","answers":{"durable":{"type":"boolean","probability":0.93},"kind":{"type":"choice","choice":"root-cause","confidence":0.8,"probabilities":{"root-cause":0.8,"decision":0.1}}},"gate":{"question":"durable","verdict":"yes"}}
EOF
}

# Run nudge from the routed repo dir with $1 on stdin; extra args pass through.
nudge_run() { # $1 = stdin text, rest = nudge args
  local in="$1"
  shift
  cd "$DEV_DIR/github.com/flocasts/app"
  run "$JOM" nudge "$@" <<<"$in"
}

NUDGE_HEURISTIC_LINE='⚠ vaultmem: notes changed this session but no Sessions/*/_index.md was updated — capture the work log / `updated:` before you stop.'
NUDGE_JUDGE_LINE='⚠ vaultmem: this session looks to hold a durable root-cause; capture it (vault-capture) before you stop.'

@test "nudge --judge prints the durable line on a confident yes, with the design 8.2 call" {
  nudge_judge_setup
  nudge_run "$HOOK_JSON" --judge
  [ "$status" -eq 0 ]
  [ "$output" = "$NUDGE_JUDGE_LINE" ]
  grep -qx 'args=capture-worthy --vault flo --subject nudge --gate durable' "$BATS_TEST_TMPDIR/stub.ran"
  state=$(cat "$BATS_TEST_TMPDIR/stub.stdin")
  [[ "$state" == *"user: why does the cache thrash?"* ]]
  [[ "$state" == *'assistant: Root cause: the "eviction" TTL was 0.'* ]]
  [[ "$state" == *"user: great, thanks"* ]]
  for leak in TOOL-OUTPUT SUBAGENT-TEXT META-CAVEAT SECRET-THOUGHT '"command"' summary; do
    [[ "$state" != *"$leak"* ]]
  done
}

@test "nudge --judge reads the Codex transcript shape and skips developer messages" {
  nudge_judge_setup
  cat >"$TRANSCRIPT" <<'EOF'
{"timestamp":"t","type":"session_meta","payload":{"id":"x"}}
{"timestamp":"t","type":"response_item","payload":{"type":"message","role":"developer","content":[{"type":"input_text","text":"DEV-INSTRUCTIONS"}]}}
{"timestamp":"t","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"pick the queue"}]}}
{"timestamp":"t","type":"event_msg","payload":{"type":"agent_message","message":"DUPLICATE-EVENT"}}
{"timestamp":"t","type":"response_item","payload":{"type":"function_call_output","call_id":"c","output":"TOOL-OUTPUT"}}
{"timestamp":"t","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Decision: SQS over Kafka."}]}}
EOF
  nudge_run "$HOOK_JSON" --judge
  [ "$status" -eq 0 ]
  [ "$output" = "$NUDGE_JUDGE_LINE" ]
  state=$(cat "$BATS_TEST_TMPDIR/stub.stdin")
  [ "$state" = "user: pick the queue

assistant: Decision: SQS over Kafka." ]
}

@test "nudge --judge appends last_assistant_message when the transcript lags it" {
  nudge_judge_setup
  json="{\"transcript_path\":\"$TRANSCRIPT\",\"last_assistant_message\":\"Pattern: retry with jitter.\\nDone.\"}"
  nudge_run "$json" --judge
  [ "$status" -eq 0 ]
  state=$(cat "$BATS_TEST_TMPDIR/stub.stdin")
  [[ "$state" == *"user: great, thanks

assistant: Pattern: retry with jitter.
Done." ]]
  # Already the newest turn in the transcript: not repeated.
  printf '%s\n' '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"same"}]}}' >>"$TRANSCRIPT"
  json="{\"transcript_path\":\"$TRANSCRIPT\",\"last_assistant_message\":\"same\"}"
  nudge_run "$json" --judge
  [ "$(grep -c '^assistant: same$' "$BATS_TEST_TMPDIR/stub.stdin")" -eq 1 ]
}

@test "nudge --judge keeps the state under 24000 bytes, newest turns whole" {
  nudge_judge_setup
  big=$(head -c 5000 /dev/zero | tr '\0' 'x')
  : >"$TRANSCRIPT"
  for i in 1 2 3 4 5 6 7 8 9 10; do
    printf '{"type":"user","message":{"role":"user","content":"turn-%s %s"}}\n' "$i" "$big" >>"$TRANSCRIPT"
  done
  nudge_run "$HOOK_JSON" --judge
  [ "$status" -eq 0 ]
  [ "$(wc -c <"$BATS_TEST_TMPDIR/stub.stdin")" -le 24000 ]
  grep -q '^user: turn-10 ' "$BATS_TEST_TMPDIR/stub.stdin"
  grep -q '^user: turn-7 ' "$BATS_TEST_TMPDIR/stub.stdin"
  run grep -c 'turn-6 ' "$BATS_TEST_TMPDIR/stub.stdin"
  [ "$output" = 0 ]
  # One turn over budget on its own: its tail is sent, still under budget.
  printf '{"type":"user","message":{"role":"user","content":"%s END"}}\n' "$(head -c 30000 /dev/zero | tr '\0' 'y')" >"$TRANSCRIPT"
  nudge_run "$HOOK_JSON" --judge
  [ "$(wc -c <"$BATS_TEST_TMPDIR/stub.stdin")" -le 24001 ]
  grep -q 'y END$' "$BATS_TEST_TMPDIR/stub.stdin"
}

@test "nudge --judge prints the heuristic line first, unchanged, then the judge line" {
  nudge_judge_setup
  touch -t 202001010000 "$XDG_CACHE_HOME/vaultmem/nudge-stamp"
  touch "$OBS_FLO/Projects/Notes.md"
  nudge_run "$HOOK_JSON" --judge
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 2 ]
  [ "${lines[0]}" = "$NUDGE_HEURISTIC_LINE" ]
  [ "${lines[1]}" = "$NUDGE_JUDGE_LINE" ]
}

@test "nudge without --judge is byte-identical with the extension installed and enabled" {
  nudge_judge_setup
  touch -t 202001010000 "$XDG_CACHE_HOME/vaultmem/nudge-stamp"
  touch "$OBS_FLO/Projects/Notes.md"
  nudge_run "$HOOK_JSON"
  [ "$status" -eq 0 ]
  with_ext="$output"
  [ ! -e "$BATS_TEST_TMPDIR/stub.ran" ]
  [ ! -e "$BATS_TEST_TMPDIR/stub.stdin" ]
  # Same vault state with no extension anywhere and no [ext.judge] block.
  mv "$VAULTMEM_EXT_DIR" "$BATS_TEST_TMPDIR/ext-gone"
  sed -i.bak '/^\[ext.judge\]/,/^$/d' "$VAULTMEM_CONFIG"
  touch -t 202001010000 "$XDG_CACHE_HOME/vaultmem/nudge-stamp"
  nudge_run "$HOOK_JSON"
  [ "$status" -eq 0 ]
  [ "$output" = "$with_ext" ]
  [ "$output" = "$NUDGE_HEURISTIC_LINE" ]
}

@test "nudge --judge never runs the judge when nudge is not in hook_judges" {
  for hj in "" "groom" "nudger, groom"; do
    nudge_judge_setup "$hj"
    nudge_run "$HOOK_JSON" --judge
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ ! -e "$BATS_TEST_TMPDIR/stub.ran" ]
  done
}

@test "nudge --judge never runs the judge for a vault that has not consented" {
  nudge_judge_setup "nudge" false
  nudge_run "$HOOK_JSON" --judge
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ ! -e "$BATS_TEST_TMPDIR/stub.ran" ]
}

@test "nudge --judge never runs the judge on a low-confidence vault guess" {
  nudge_judge_setup
  # jay consents, but it is only the fallback for this dir, not a routing match.
  mkdir -p "$BATS_TEST_TMPDIR/elsewhere"
  cd "$BATS_TEST_TMPDIR/elsewhere"
  run "$JOM" nudge --judge <<<"$HOOK_JSON"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ ! -e "$BATS_TEST_TMPDIR/stub.ran" ]
}

@test "nudge --judge is inert when [ext.judge] is disabled" {
  nudge_judge_setup
  sed -i.bak 's/^enabled = true/enabled = false/' "$VAULTMEM_CONFIG"
  nudge_run "$HOOK_JSON" --judge
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ ! -e "$BATS_TEST_TMPDIR/stub.ran" ]
}

@test "nudge --judge does not judge when a session _index.md was updated" {
  nudge_judge_setup
  touch "$OBS_FLO/Sessions/live/_index.md"
  nudge_run "$HOOK_JSON" --judge
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ ! -e "$BATS_TEST_TMPDIR/stub.ran" ]
}

@test "nudge --judge prints nothing extra on non-JSON stdin or a missing transcript_path" {
  nudge_judge_setup
  for in in "not json at all" "" '{"session_id":"s","stop_hook_active":false}' \
    '{"transcript_path":null}' "{\"transcript_path\":\"$BATS_TEST_TMPDIR/missing.jsonl\"}"; do
    nudge_run "$in" --judge
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ ! -e "$BATS_TEST_TMPDIR/stub.ran" ]
  done
}

@test "nudge --judge prints nothing extra when the judge exits 1, 2, or 3" {
  nudge_judge_setup
  for rc in 1 2 3; do
    : >"$BATS_TEST_TMPDIR/stub.ran"
    STUB_RC=$rc nudge_run "$HOOK_JSON" --judge
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    grep -q '^args=capture-worthy' "$BATS_TEST_TMPDIR/stub.ran"
  done
}

@test "nudge --judge prints nothing extra for kind none, a missing kind, or junk output" {
  nudge_judge_setup
  for out in \
    '{"id":"j","answers":{"durable":{"probability":0.9},"kind":{"type":"choice","choice":"none"}}}' \
    '{"id":"j","answers":{"durable":{"probability":0.9}}}' \
    'not json' ''; do
    printf '%s\n' "$out" >"$BATS_TEST_TMPDIR/stub.out"
    nudge_run "$HOOK_JSON" --judge
    [ "$status" -eq 0 ]
    [ -z "$output" ]
  done
}

@test "nudge --judge with the extension not installed prints nothing extra" {
  nudge_judge_setup
  mv "$VAULTMEM_EXT_DIR" "$BATS_TEST_TMPDIR/ext-gone"
  nudge_run "$HOOK_JSON" --judge
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "usage documents nudge --judge" {
  run "$OM"
  [ "$status" -eq 0 ]
  [[ "$output" == *"vaultmem nudge [--judge]"* ]]
}

@test "which routes by match_paths on a vault with no match_owners" {
  cat >"$VAULTMEM_CONFIG" <<EOF
[vault.flo]
path = "$OBS_FLO"
match_paths = "$DEV_DIR/work/**"

[vault.jay]
path = "$OBS_JAY"
EOF
  mkdir -p "$DEV_DIR/work/app"
  run "$OM" which "$DEV_DIR/work/app"
  [ "$status" -eq 0 ]
  [ "$output" = flo ]
}
