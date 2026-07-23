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
