# Development

Working notes for changing `vaultmem` itself. Install/usage lives in the
[README](../README.md); the cold-agent map is [AGENTS.md](../AGENTS.md).

## The bash 3.2 floor

**`vaultmem` must run on bash 3.2.** Write for 3.2, not for whatever bash is on
your `$PATH`.

macOS still ships bash **3.2.57** as `/bin/bash`, frozen since 2007 — Apple will
not ship bash 4+ because it is GPLv3. That shell is what a plain macOS user
gets, and what the `SessionStart` hooks run under. Most contributors have a much
newer bash from Homebrew (`/opt/homebrew/bin/bash`, 5.x), so **bash-4 syntax
passes every local check and fails only on macOS** — sometimes silently.

### Banned constructs

| Construct | Since | Use instead |
|---|---|---|
| `declare -A` / `local -A` (associative arrays) | 4.0 | sorted `key<TAB>value` temp file + `join`/`awk`, or a newline-delimited set matched with `case` |
| `mapfile` / `readarray` | 4.0 | `arr=(); while IFS= read -r x; do arr+=("$x"); done < <(...)` |
| `${x^^}` / `${x,,}` (case modification) | 4.0 | `$(printf '%s' "$x" \| tr '[:upper:]' '[:lower:]')` |
| `\|&` (pipe stdout+stderr) | 4.0 | `2>&1 \|` |
| `&>>` (append both) | 4.0 | `>>file 2>&1` |
| `coproc` | 4.0 | explicit fifos or temp files |

### Why this is worth a rule rather than a code review habit

Both constructs that have actually reached `main` failed **silently**, not
loudly:

- **`local -A` in `doctor --deep`.** bash 3.2 errored on the declaration, then
  parsed the following `indexed[$tp]=1` as an *indexed* array assignment whose
  subscript is an arithmetic expression — so a file path became a syntax error
  per note, and the command still **exited 0**. It looked like a clean run that
  simply found nothing.
- **`mapfile` in `tests/subcommand-lint.sh`.** Inside a process substitution,
  `set -e` does not fire, so the array stayed empty and the lint **passed
  vacuously** on the one platform it most needed to run on. A test that cannot
  fail is worse than no test.

A file-scope `declare -A` is worse still: its error prints on *every*
invocation, which would break the fail-quiet contract that `status` and
`sessions` rely on (see [hooks.md](hooks.md)).

### How it is enforced

`shellcheck` **cannot** catch this — it takes a dialect (`sh`/`bash`/`dash`/
`ksh`/`busybox`), not a bash *version*, so `local -A` and `mapfile` are clean to
it. Enforcement is therefore two layers vaultmem owns:

1. **`./tests/bash32-lint.sh`** — greps for the constructs above and prints the
   file, line, and the portable replacement. Fast and specific, but only knows
   the constructs it lists.
2. **A CI job that runs the whole bats suite under `/bin/bash`** (the `bash32`
   job). This is the real net: it catches the entire class, including a bash-4
   construct on a code path that only breaks when exercised.

Locally, before pushing anything non-trivial:

```bash
BASH=/bin/bash bats tests/vaultmem.bats   # the suite, under macOS system bash
./tests/bash32-lint.sh                     # the fast specific check
```

Note that the ordinary `bats (macos-latest)` matrix job does **not** cover this:
`brew install bats-core` pulls in bash 5, and bats runs under that.

### Portable patterns that are also faster

Reaching for an associative array is usually a signal to reach for a file and a
single `awk` pass instead — which tends to win anyway, because it replaces N
subprocess round-trips with one:

- **Lookup table** — build a sorted `key<TAB>path` temp file once, then resolve
  a whole batch with one `awk` (`NR==FNR{map[$1]=$2; next} {print map[$0]}`).
  This is what `_build_resolve_cache` does; batching the lookups took `frontier`
  from 73s to 7.4s, and the portable version beat the associative-array draft
  it replaced (8.9s).
- **Counting** — `sort | uniq -c` rather than incrementing map entries in a
  bash loop.
- **Membership** — a newline-delimited string plus
  `case "$set" in *$'\n'"$x"$'\n'*)`. Safe for file paths, which can contain
  spaces but never newlines.

## Running the checks

The full gate, matching CI:

```bash
bats tests/vaultmem.bats
BASH=/bin/bash bats tests/vaultmem.bats
./tests/subcommand-lint.sh
./tests/bash32-lint.sh
shellcheck vaultmem install.sh tests/subcommand-lint.sh tests/bash32-lint.sh
shfmt --diff vaultmem install.sh tests/subcommand-lint.sh tests/bash32-lint.sh
```

Two things that differ from a naive local run:

- **CI `shellcheck` is stricter than a bare local `shellcheck`.** Use
  `shellcheck -S style` locally to see what CI sees.
- **`shfmt --diff` is a separate gate from shellcheck.** A change can pass
  shellcheck and still fail CI on formatting; run `shfmt -w <file>` first.

## Tests

`tests/vaultmem.bats` never touches a real vault. Each test builds a throwaway
two-vault registry under `$BATS_TEST_TMPDIR` with `VAULTMEM_CONFIG` pointed at
it. Follow that pattern for new tests — never point one at
`~/.config/vaultmem/config.toml` or a real vault path.

When changing behavior that is meant to stay identical (a performance fix, a
refactor), write the test so it passes against **both** the old and new
implementation, and capture real before/after output to diff. `frontier`'s
score column drifts between runs on its own (`exp(-days/30)` decay), so compare
the `out=`/`in=` columns, not whole lines.
