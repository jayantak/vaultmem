#!/usr/bin/env bats

# Tests for the judge extension (ext/judge/vaultmem-judge).
# Run: bats tests/judge.bats
#
# Isolation: no network, no real vault, no real config. VAULTMEM_BIN is a stub
# that prints the `judge config` contract, and a fake `curl` sits first on PATH,
# records its argv + stdin + request body, and replays a canned response from
# tests/fixtures/judge/.
#
# bash 3.2: bash resets $BASH at startup, so `BASH=/bin/bash bats …` alone does
# not change the shell the extension runs under. Set VAULTMEM_TEST_BASH=/bin/bash
# (CI's bash32 job does) to run every extension call under that interpreter.

KEY_VALUE="vck_TESTKEY_never_print_me_0123456789"
STATE_TEXT="The build failed with exit code 1."

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  JUDGE="$ROOT/ext/judge/vaultmem-judge"
  FIX="$ROOT/tests/fixtures/judge"
  JUDGE_SH="${VAULTMEM_TEST_BASH:-bash}"

  export HOME="$BATS_TEST_TMPDIR/home"
  export XDG_CONFIG_HOME="$BATS_TEST_TMPDIR/xdg-config"
  export XDG_STATE_HOME="$BATS_TEST_TMPDIR/xdg-state"
  mkdir -p "$HOME" "$XDG_CONFIG_HOME/vaultmem/judges" "$BATS_TEST_TMPDIR/bin"
  LOG="$XDG_STATE_HOME/vaultmem/judge.jsonl"
  STDERR="$BATS_TEST_TMPDIR/stderr"
  unset VAULTMEM_JUDGE_LOG_MAX_BYTES

  export AI_GATEWAY_API_KEY="$KEY_VALUE"

  # Stub core: `judge config` prints the contract; `which` prints a vault id.
  export STUB_CONFIG="$BATS_TEST_TMPDIR/judge-config"
  export STUB_WHICH_ID="personal" STUB_WHICH_ERR=""
  export VAULTMEM_BIN="$BATS_TEST_TMPDIR/bin/vaultmem-stub"
  cat >"$VAULTMEM_BIN" <<'EOF'
#!/usr/bin/env bash
case "$1 ${2:-}" in
"judge config") cat "$STUB_CONFIG" ;;
"which "*)
  printf '%s\n' "$STUB_WHICH_ID"
  [ -z "$STUB_WHICH_ERR" ] || printf '%s\n' "$STUB_WHICH_ERR" >&2
  ;;
*) exit 64 ;;
esac
EOF
  chmod +x "$VAULTMEM_BIN"
  write_config

  # Fake curl, first on PATH.
  export CURL_REC="$BATS_TEST_TMPDIR/curl-rec"
  export FAKE_CURL_RESPONSE="$FIX/boolean-yes.json" FAKE_CURL_HTTP=200 FAKE_CURL_EXIT=0
  cat >"$BATS_TEST_TMPDIR/bin/curl" <<'EOF'
#!/usr/bin/env bash
mkdir -p "$CURL_REC"
printf 'x\n' >>"$CURL_REC/calls"
printf '%s\n' "$@" >"$CURL_REC/argv"
cat >"$CURL_REC/stdin"
out=""
prev=""
for a in "$@"; do
  case "$prev" in
  --output) out="$a" ;;
  --data-binary) cp "${a#@}" "$CURL_REC/body" ;;
  esac
  prev="$a"
done
if [ "$FAKE_CURL_EXIT" -ne 0 ]; then
  exit "$FAKE_CURL_EXIT"
fi
[ -n "$out" ] && cp "$FAKE_CURL_RESPONSE" "$out"
printf '%s 0.212' "$FAKE_CURL_HTTP"
EOF
  chmod +x "$BATS_TEST_TMPDIR/bin/curl"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
}

# write_config [key=value …]: the core contract, with per-test overrides.
write_config() {
  local enabled=true zdr=true log=true timeout_ms=1500 personal=true work=false
  local base_url="https://ai-gateway.vercel.sh" key_file="$HOME/.config/vaultmem/ai-gateway.key" extra=""
  local kv
  for kv in "$@"; do
    case "$kv" in
    extra=*) extra="${kv#extra=}" ;;
    *) eval "${kv%%=*}=\"\${kv#*=}\"" ;;
    esac
  done
  {
    printf 'ext.judge.enabled=%s\n' "$enabled"
    printf 'ext.judge.model=typesafe-ai/jev\n'
    printf 'ext.judge.base_url=%s\n' "$base_url"
    printf 'ext.judge.zdr=%s\n' "$zdr"
    printf 'ext.judge.timeout_ms=%s\n' "$timeout_ms"
    printf 'ext.judge.key_file=%s\n' "$key_file"
    printf 'ext.judge.log=%s\n' "$log"
    printf 'ext.judge.rerank=false\n'
    printf 'ext.judge.hook_judges=\n'
    [ -z "$extra" ] || printf '%s\n' "$extra"
    printf 'vault.personal.judge=%s\n' "$personal"
    printf 'vault.work.judge=%s\n' "$work"
  } >"$STUB_CONFIG"
}

# judge_in <state> <args…>: state on stdin; stdout only in $output, stderr in $STDERR.
judge_in() {
  local state="$1"
  shift
  printf '%s' "$state" | "$JUDGE_SH" "$JUDGE" "$@" 2>"$STDERR"
}

judge_cmd() { "$JUDGE_SH" "$JUDGE" "$@" 2>"$STDERR" </dev/null; }

curl_not_invoked() { [ ! -e "$CURL_REC/calls" ]; }

use_outcome_judge() { cp "$FIX/outcome-judge.json" "$XDG_CONFIG_HOME/vaultmem/judges/outcome.json"; }

# --- thresholds → exit codes ----------------------------------------------------

@test "gate: confident yes exits 0" {
  run judge_in "$STATE_TEXT" smoke --vault personal --gate failed
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.gate.verdict')" = "yes" ]
  [ "$(printf '%s' "$output" | jq -r '.answers.failed.probability')" = "0.99" ]
}

@test "gate: confident no exits 1" {
  FAKE_CURL_RESPONSE="$FIX/boolean-no.json" run judge_in "$STATE_TEXT" smoke --vault personal --gate failed
  [ "$status" -eq 1 ]
  [ "$(printf '%s' "$output" | jq -r '.gate.verdict')" = "no" ]
}

@test "gate: between thresholds abstains with exit 2" {
  FAKE_CURL_RESPONSE="$FIX/boolean-abstain.json" run judge_in "$STATE_TEXT" smoke --vault personal --gate failed
  [ "$status" -eq 2 ]
  [ "$(printf '%s' "$output" | jq -r '.gate.verdict')" = "abstain" ]
}

@test "gate: thresholds come from the judge file, not a constant" {
  # outcome-judge sets yes=0.9; a 0.87 answer would pass the 0.85 default.
  use_outcome_judge
  jq '.answers.failed.probability = 0.87' "$FIX/boolean-yes.json" >"$BATS_TEST_TMPDIR/resp.json"
  FAKE_CURL_RESPONSE="$BATS_TEST_TMPDIR/resp.json" run judge_in "$STATE_TEXT" outcome --vault personal --gate failed
  [ "$status" -eq 2 ]
}

@test "gate on a choice: top probability below min_confidence exits 2" {
  use_outcome_judge
  FAKE_CURL_RESPONSE="$FIX/choice-low.json" run judge_in "$STATE_TEXT" outcome --vault personal --gate outcome
  [ "$status" -eq 2 ]
}

@test "gate on a choice: confident top choice exits 0" {
  use_outcome_judge
  jq '{model, answers: {outcome: .answers.outcome}}' "$FIX/mixed.json" >"$BATS_TEST_TMPDIR/resp.json"
  FAKE_CURL_RESPONSE="$BATS_TEST_TMPDIR/resp.json" run judge_in "$STATE_TEXT" outcome --vault personal --gate outcome
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.answers.outcome.choice')" = "failed" ]
}

@test "without --gate: exit 0 and the answers JSON keeps gateway fields" {
  use_outcome_judge
  FAKE_CURL_RESPONSE="$FIX/mixed.json" run judge_in "$STATE_TEXT" outcome --vault personal
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.answers.severity.confidence')" = "0.99" ]
  [ "$(printf '%s' "$output" | jq -r '.judge')" = "outcome" ]
  [ "$(printf '%s' "$output" | jq 'has("gate")')" = "false" ]
  printf '%s' "$output" | jq -e '.id | test("^[0-9]{8}T[0-9]{6}Z-[0-9a-f]{4}$")'
}

@test "without --gate: a low probability is still exit 0" {
  FAKE_CURL_RESPONSE="$FIX/boolean-no.json" run judge_in "$STATE_TEXT" smoke --vault personal
  [ "$status" -eq 0 ]
}

@test "--format tsv prints one row per question" {
  use_outcome_judge
  FAKE_CURL_RESPONSE="$FIX/mixed.json" run judge_in "$STATE_TEXT" outcome --vault personal --format tsv
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 3 ]
  printf '%s\n' "$output" | grep -q "^failed	boolean	yes	0.99$"
  printf '%s\n' "$output" | grep -q "^outcome	choice	failed	1$"
  printf '%s\n' "$output" | grep -q "^severity	score	1.99	$"
}

# --- egress gate: exit 3 BEFORE any network call ---------------------------------

@test "egress: enabled=false exits 3 and curl is never invoked" {
  write_config enabled=false
  run judge_in "$STATE_TEXT" smoke --vault personal --gate failed
  [ "$status" -eq 3 ]
  [ -z "$output" ]
  curl_not_invoked
}

@test "egress: a judge=false vault exits 3 and curl is never invoked" {
  run judge_in "$STATE_TEXT" smoke --vault work --gate failed
  [ "$status" -eq 3 ]
  [ -z "$output" ]
  curl_not_invoked
}

@test "egress: a vault missing from the config exits 3 and curl is never invoked" {
  run judge_in "$STATE_TEXT" smoke --vault nosuch --gate failed
  [ "$status" -eq 3 ]
  curl_not_invoked
}

@test "egress: no vault id resolved exits 3 and curl is never invoked" {
  # `which` fell back to the default vault: a low-confidence guess is not consent.
  STUB_WHICH_ERR="vaultmem: low-confidence guess (no match signal) → personal" \
    run judge_in "$STATE_TEXT" smoke --gate failed
  [ "$status" -eq 3 ]
  [ -z "$output" ]
  curl_not_invoked
}

@test "egress: without --vault a confident \`which\` to a consenting vault proceeds" {
  run judge_in "$STATE_TEXT" smoke --gate failed
  [ "$status" -eq 0 ]
  [ "$(tail -n 1 "$LOG" | jq -r '.vault')" = "personal" ]
}

@test "egress: without --vault a confident \`which\` to a non-consenting vault exits 3" {
  STUB_WHICH_ID=work run judge_in "$STATE_TEXT" smoke --gate failed
  [ "$status" -eq 3 ]
  curl_not_invoked
}

@test "egress: config unavailable exits 3 and curl is never invoked" {
  VAULTMEM_BIN="$BATS_TEST_TMPDIR/bin/does-not-exist" run judge_in "$STATE_TEXT" smoke --vault personal
  [ "$status" -eq 3 ]
  curl_not_invoked
}

@test "egress: a plain-http base_url exits 3 and curl is never invoked" {
  write_config base_url=http://gateway.example.com
  run judge_in "$STATE_TEXT" smoke --vault personal
  [ "$status" -eq 3 ]
  curl_not_invoked
}

@test "an invalid judge file exits 3 and curl is never invoked" {
  printf '{"version":1,"questions":{"q":{"type":"noul"}}}' >"$XDG_CONFIG_HOME/vaultmem/judges/bad.json"
  run judge_in "$STATE_TEXT" bad --vault personal
  [ "$status" -eq 3 ]
  [ -z "$output" ]
  curl_not_invoked
}

# --- failure modes: exit 3, empty stdout -------------------------------------------

@test "timeout exits 3 with empty stdout, and --max-time comes from timeout_ms" {
  write_config timeout_ms=2500
  FAKE_CURL_EXIT=28 run judge_in "$STATE_TEXT" smoke --vault personal --gate failed
  [ "$status" -eq 3 ]
  [ -z "$output" ]
  grep -A1 -x -- '--max-time' "$CURL_REC/argv" | grep -qx '2.500'
  grep -q 'timeout' "$STDERR"
}

@test "HTTP 400 exits 3 with empty stdout" {
  FAKE_CURL_RESPONSE="$FIX/error-400.json" FAKE_CURL_HTTP=400 run judge_in "$STATE_TEXT" smoke --vault personal --gate failed
  [ "$status" -eq 3 ]
  [ -z "$output" ]
  grep -q 'invalid_request_error' "$STDERR"
}

@test "HTTP 401 exits 3 with empty stdout and names the error type" {
  FAKE_CURL_RESPONSE="$FIX/error-401.json" FAKE_CURL_HTTP=401 run judge_in "$STATE_TEXT" smoke --vault personal --gate failed
  [ "$status" -eq 3 ]
  [ -z "$output" ]
  grep -q 'authentication_error' "$STDERR"
  [ "$(tail -n 1 "$LOG" | jq -r '"\(.http) \(.error.type) \(.answers)"')" = "401 authentication_error null" ]
}

@test "HTTP 404 exits 3 with empty stdout" {
  FAKE_CURL_RESPONSE="$FIX/error-404.json" FAKE_CURL_HTTP=404 run judge_in "$STATE_TEXT" smoke --vault personal
  [ "$status" -eq 3 ]
  [ -z "$output" ]
  grep -q 'model_not_found' "$STDERR"
}

@test "HTTP 500 exits 3 with empty stdout" {
  FAKE_CURL_RESPONSE="$FIX/error-500.json" FAKE_CURL_HTTP=500 run judge_in "$STATE_TEXT" smoke --vault personal --gate failed
  [ "$status" -eq 3 ]
  [ -z "$output" ]
}

@test "HTTP 502 with a non-JSON error body exits 3 with empty stdout" {
  FAKE_CURL_RESPONSE="$FIX/malformed.txt" FAKE_CURL_HTTP=502 run judge_in "$STATE_TEXT" smoke --vault personal --gate failed
  [ "$status" -eq 3 ]
  [ -z "$output" ]
}

@test "malformed JSON on a 200 exits 3 with empty stdout" {
  FAKE_CURL_RESPONSE="$FIX/malformed.txt" run judge_in "$STATE_TEXT" smoke --vault personal --gate failed
  [ "$status" -eq 3 ]
  [ -z "$output" ]
  [ "$(tail -n 1 "$LOG" | jq -r '.error.type')" = "bad_response" ]
}

@test "a 200 with no usable answers exits 3 with empty stdout" {
  FAKE_CURL_RESPONSE="$FIX/empty-answers.json" run judge_in "$STATE_TEXT" smoke --vault personal
  [ "$status" -eq 3 ]
  [ -z "$output" ]
}

@test "a 200 missing the gated question exits 3" {
  use_outcome_judge
  FAKE_CURL_RESPONSE="$FIX/boolean-yes.json" run judge_in "$STATE_TEXT" outcome --vault personal --gate outcome
  [ "$status" -eq 3 ]
  [ -z "$output" ]
}

@test "ZDR refusal exits 3, empty stdout, and is never retried without the flag" {
  FAKE_CURL_RESPONSE="$FIX/error-403-zdr.json" FAKE_CURL_HTTP=403 run judge_in "$STATE_TEXT" smoke --vault personal --gate failed
  [ "$status" -eq 3 ]
  [ -z "$output" ]
  [ "$(wc -l <"$CURL_REC/calls" | tr -d ' ')" -eq 1 ]
  jq -e '.providerOptions.gateway.zeroDataRetention == true' "$CURL_REC/body"
  grep -q 'zero data retention' "$STDERR"
  # The extension never suggests the downgrade at runtime.
  ! grep -q 'zdr = false' "$STDERR"
}

# --- request body -------------------------------------------------------------------

@test "request body matches the golden file under zdr=true" {
  run judge_in "$STATE_TEXT" smoke --vault personal
  [ "$status" -eq 0 ]
  diff <(jq -S . "$CURL_REC/body") <(jq -S . "$FIX/smoke-body-zdr.json")
}

@test "request body matches the golden file under zdr=false: no zeroDataRetention" {
  write_config zdr=false
  run judge_in "$STATE_TEXT" smoke --vault personal
  [ "$status" -eq 0 ]
  diff <(jq -S . "$CURL_REC/body") <(jq -S . "$FIX/smoke-body-nozdr.json")
  ! grep -q 'zeroDataRetention' "$CURL_REC/body"
}

@test "request goes to POST {base_url}/v1/evaluate" {
  write_config base_url=https://gw.example.test/
  run judge_in "$STATE_TEXT" smoke --vault personal
  [ "$status" -eq 0 ]
  grep -qx 'https://gw.example.test/v1/evaluate' "$CURL_REC/argv"
  grep -A1 -x -- '--request' "$CURL_REC/argv" | grep -qx 'POST'
}

@test "state with quotes, backslashes, and newlines survives as one JSON string" {
  local tricky
  tricky=$(printf 'say "yes"\\n\nline2 \\ end\t{"a":1}')
  run judge_in "$tricky" smoke --vault personal
  [ "$status" -eq 0 ]
  [ "$(jq -r '.state' "$CURL_REC/body")" = "$tricky" ]
}

@test "--gate sends only the gated question" {
  use_outcome_judge
  run judge_in "$STATE_TEXT" outcome --vault personal --gate failed
  [ "$(jq -c '.questions | keys' "$CURL_REC/body")" = '["failed"]' ]
}

@test "state is truncated to max_state_bytes, tail-biased, and logged as truncated" {
  use_outcome_judge
  FAKE_CURL_RESPONSE="$FIX/mixed.json" run judge_in "0123456789ABCDEFGHIJ" outcome --vault personal
  [ "$status" -eq 0 ]
  [ "$(jq -r '.state' "$CURL_REC/body")" = "ABCDEFGHIJ" ]
  [ "$(tail -n 1 "$LOG" | jq -r '.truncated')" = "true" ]
}

@test "head-biased truncation keeps the start of the state" {
  jq '.truncate = "head"' "$FIX/outcome-judge.json" >"$XDG_CONFIG_HOME/vaultmem/judges/outcome.json"
  FAKE_CURL_RESPONSE="$FIX/mixed.json" run judge_in "0123456789ABCDEFGHIJ" outcome --vault personal
  [ "$status" -eq 0 ]
  [ "$(jq -r '.state' "$CURL_REC/body")" = "0123456789" ]
}

@test "a user judge file overrides the shipped one of the same name" {
  jq '.questions.failed.instructions = "USER OVERRIDE"' "$ROOT/ext/judge/judges/smoke.json" \
    >"$XDG_CONFIG_HOME/vaultmem/judges/smoke.json"
  run judge_in "$STATE_TEXT" smoke --vault personal
  [ "$status" -eq 0 ]
  [ "$(jq -r '.questions.failed.instructions' "$CURL_REC/body")" = "USER OVERRIDE" ]
}

# --- the key ------------------------------------------------------------------------

@test "key from the environment never reaches argv, stdout, stderr, or the log" {
  run judge_in "$STATE_TEXT" smoke --vault personal --gate failed
  [ "$status" -eq 0 ]
  ! grep -q "$KEY_VALUE" "$CURL_REC/argv"
  ! grep -q -- 'Authorization' "$CURL_REC/argv"
  [[ "$output" != *"$KEY_VALUE"* ]]
  ! grep -q "$KEY_VALUE" "$STDERR"
  ! grep -q "$KEY_VALUE" "$LOG"
  ! grep -q "$KEY_VALUE" "$CURL_REC/body"
  # It travels on curl's stdin (--config -), and only there.
  grep -qx -- '-' <(grep -A1 -x -- '--config' "$CURL_REC/argv" | tail -n 1)
  grep -q "Authorization: Bearer $KEY_VALUE" "$CURL_REC/stdin"
}

@test "key stays secret on the failure path, even if the gateway echoes it" {
  jq --arg k "$KEY_VALUE" '.error.message = "bad key " + $k' "$FIX/error-401.json" >"$BATS_TEST_TMPDIR/resp.json"
  FAKE_CURL_RESPONSE="$BATS_TEST_TMPDIR/resp.json" FAKE_CURL_HTTP=401 run judge_in "$STATE_TEXT" smoke --vault personal
  [ "$status" -eq 3 ]
  ! grep -q "$KEY_VALUE" "$CURL_REC/argv"
  [ -z "$output" ]
  ! grep -q "$KEY_VALUE" "$STDERR"
  ! grep -q "$KEY_VALUE" "$LOG"
  grep -q 'redacted' "$LOG"
}

@test "key_file with mode 600 is used when AI_GATEWAY_API_KEY is unset" {
  unset AI_GATEWAY_API_KEY
  mkdir -p "$HOME/.config/vaultmem"
  printf '%s\n' "$KEY_VALUE" >"$HOME/.config/vaultmem/ai-gateway.key"
  chmod 600 "$HOME/.config/vaultmem/ai-gateway.key"
  run judge_in "$STATE_TEXT" smoke --vault personal --gate failed
  [ "$status" -eq 0 ]
  grep -q "Authorization: Bearer $KEY_VALUE" "$CURL_REC/stdin"
  ! grep -q "$KEY_VALUE" "$CURL_REC/argv"
  ! grep -q "$KEY_VALUE" "$LOG"
}

@test "key_file given with a leading ~ is expanded" {
  unset AI_GATEWAY_API_KEY
  write_config 'key_file=~/k/gw.key'
  mkdir -p "$HOME/k"
  printf '%s\n' "$KEY_VALUE" >"$HOME/k/gw.key"
  chmod 600 "$HOME/k/gw.key"
  run judge_in "$STATE_TEXT" smoke --vault personal
  [ "$status" -eq 0 ]
}

@test "key_file wider than 600 is refused: exit 3, curl never invoked" {
  unset AI_GATEWAY_API_KEY
  mkdir -p "$HOME/.config/vaultmem"
  printf '%s\n' "$KEY_VALUE" >"$HOME/.config/vaultmem/ai-gateway.key"
  chmod 640 "$HOME/.config/vaultmem/ai-gateway.key"
  run judge_in "$STATE_TEXT" smoke --vault personal
  [ "$status" -eq 3 ]
  [ -z "$output" ]
  curl_not_invoked
  ! grep -q "$KEY_VALUE" "$STDERR"
}

@test "no key at all exits 3 and curl is never invoked" {
  unset AI_GATEWAY_API_KEY
  run judge_in "$STATE_TEXT" smoke --vault personal
  [ "$status" -eq 3 ]
  curl_not_invoked
}

# --- decision log -------------------------------------------------------------------

@test "log row matches the design shape and holds no state text" {
  run judge_in "$STATE_TEXT" smoke --vault personal --subject "Sessions/foo/_index.md"
  [ "$status" -eq 0 ]
  [ "$(wc -l <"$LOG" | tr -d ' ')" -eq 1 ]
  [ "$(jq -c 'keys' "$LOG")" = '["answers","cost","feedback","http","id","input_tokens","judge","latency_ms","market_cost","model","state_sha256","subject","truncated","ts","vault"]' ]
  local want
  want=$(printf '%s' "$STATE_TEXT" | shasum -a 256 2>/dev/null | awk '{print $1}')
  [ -n "$want" ] || want=$(printf '%s' "$STATE_TEXT" | sha256sum | awk '{print $1}')
  [ "$(jq -r '.state_sha256' "$LOG")" = "$want" ]
  [ "$(jq -r '[.judge, .vault, .subject, .model, .truncated, .http, .input_tokens, .cost, .market_cost, .latency_ms, .feedback] | @tsv' "$LOG")" = \
    "smoke	personal	Sessions/foo/_index.md	typesafe-ai/jev	false	200	304	0	0.000012768	212	" ]
  [ "$(jq -r '.answers.failed.probability' "$LOG")" = "0.99" ]
  jq -e '.ts | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$")' "$LOG"
  ! grep -q 'build failed' "$LOG"
  # The id on stdout is the id in the log, so feedback can key on it later.
  [ "$(printf '%s' "$output" | jq -r '.id')" = "$(jq -r '.id' "$LOG")" ]
}

@test "log=false writes nothing" {
  write_config log=false
  run judge_in "$STATE_TEXT" smoke --vault personal
  [ "$status" -eq 0 ]
  [ ! -e "$LOG" ]
}

@test "an egress-denied call writes no log row" {
  run judge_in "$STATE_TEXT" smoke --vault work
  [ "$status" -eq 3 ]
  [ ! -e "$LOG" ]
}

@test "rotation: the live file moves to .1, an older .1 is replaced, log -n spans both" {
  mkdir -p "$(dirname "$LOG")"
  printf '{"id":"ancient"}\n' >"$LOG.1"
  printf '{"id":"old-1"}\n{"id":"old-2"}\n' >"$LOG"
  VAULTMEM_JUDGE_LOG_MAX_BYTES=10 run judge_in "$STATE_TEXT" smoke --vault personal
  [ "$status" -eq 0 ]
  [ "$(jq -r '.id' "$LOG.1" | tr '\n' ' ')" = "old-1 old-2 " ]
  [ "$(wc -l <"$LOG" | tr -d ' ')" -eq 1 ]
  [ "$(jq -r '.judge' "$LOG")" = "smoke" ]
  ! grep -q ancient "$LOG" "$LOG.1"

  run judge_cmd log -n 2
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 2 ]
  [ "$(printf '%s\n' "${lines[0]}" | jq -r '.id')" = "old-2" ]
  [ "$(printf '%s\n' "${lines[1]}" | jq -r '.judge')" = "smoke" ]
}

@test "rotation: below the limit nothing moves" {
  mkdir -p "$(dirname "$LOG")"
  printf '{"id":"old-1"}\n' >"$LOG"
  VAULTMEM_JUDGE_LOG_MAX_BYTES=100000 run judge_in "$STATE_TEXT" smoke --vault personal
  [ "$status" -eq 0 ]
  [ ! -e "$LOG.1" ]
  [ "$(wc -l <"$LOG" | tr -d ' ')" -eq 2 ]
}

@test "rotation failure never fails the call: the log write is skipped" {
  [ "$(id -u)" -ne 0 ] || skip "root ignores directory permissions"
  mkdir -p "$(dirname "$LOG")"
  printf '{"id":"old-1"}\n' >"$LOG"
  chmod 555 "$(dirname "$LOG")"
  VAULTMEM_JUDGE_LOG_MAX_BYTES=10 run judge_in "$STATE_TEXT" smoke --vault personal --gate failed
  chmod 755 "$(dirname "$LOG")"
  [ "$status" -eq 0 ]
  [ "$(cat "$LOG")" = '{"id":"old-1"}' ]
  [ ! -e "$LOG.1" ]
}

@test "log: -n limits rows, no log file prints nothing" {
  run judge_cmd log
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  mkdir -p "$(dirname "$LOG")"
  printf '{"id":"a"}\n{"id":"b"}\n{"id":"c"}\n' >"$LOG"
  run judge_cmd log -n 1
  [ "$output" = '{"id":"c"}' ]
  run judge_cmd log
  [ "${#lines[@]}" -eq 3 ]
  run judge_cmd log -n x
  [ "$status" -eq 64 ]
}

# --- usage errors --------------------------------------------------------------------

@test "usage errors exit 64 and never invoke curl" {
  run judge_cmd
  [ "$status" -eq 64 ]
  run judge_in "$STATE_TEXT" smoke --vault personal --format xml
  [ "$status" -eq 64 ]
  run judge_in "$STATE_TEXT" smoke --bogus
  [ "$status" -eq 64 ]
  run judge_in "$STATE_TEXT" smoke --vault
  [ "$status" -eq 64 ]
  run judge_in "$STATE_TEXT" nosuchjudge --vault personal
  [ "$status" -eq 64 ]
  run judge_in "$STATE_TEXT" ../smoke --vault personal
  [ "$status" -eq 64 ]
  run judge_in "$STATE_TEXT" smoke --vault personal --gate nosuchquestion
  [ "$status" -eq 64 ]
  curl_not_invoked
}

@test "--gate on a score question is a usage error" {
  use_outcome_judge
  run judge_in "$STATE_TEXT" outcome --vault personal --gate severity
  [ "$status" -eq 64 ]
  curl_not_invoked
}

@test "later-phase subcommands are usage errors for now" {
  run judge_cmd bench
  [ "$status" -eq 64 ]
}

@test "feedback and calibration usage errors exit 64" {
  run judge_cmd feedback
  [ "$status" -eq 64 ]
  run judge_cmd feedback only-an-id
  [ "$status" -eq 64 ]
  run judge_cmd feedback an-id maybe
  [ "$status" -eq 64 ]
  run judge_cmd calibration --format xml
  [ "$status" -eq 64 ]
  run judge_cmd calibration --bogus
  [ "$status" -eq 64 ]
  run judge_cmd calibration --judge
  [ "$status" -eq 64 ]
  curl_not_invoked
}

# --- list ---------------------------------------------------------------------------

@test "list shows shipped judges, and a user file wins over a shipped one" {
  run judge_cmd list
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -q "^smoke	shipped	"
  use_outcome_judge
  cp "$ROOT/ext/judge/judges/smoke.json" "$XDG_CONFIG_HOME/vaultmem/judges/smoke.json"
  run judge_cmd list
  printf '%s\n' "$output" | grep -q "^smoke	user	"
  printf '%s\n' "$output" | grep -q "^outcome	user	"
  [ "$(printf '%s\n' "$output" | grep -c '^smoke	')" -eq 1 ]
}

# --- doctor -------------------------------------------------------------------------

@test "doctor: a healthy setup exits 0 and never prints the key" {
  run judge_cmd doctor
  [ "$status" -eq 0 ]
  [[ "$output" == *"key present"* ]]
  [[ "$output" == *"judges/smoke.json"* ]]
  [[ "$output" != *"$KEY_VALUE"* ]]
  ! grep -q "$KEY_VALUE" "$STDERR"
  curl_not_invoked
}

@test "doctor: an unknown [ext.judge] key is an error" {
  write_config extra=ext.judge.key_cmd=/bin/evil
  run judge_cmd doctor
  [ "$status" -eq 1 ]
  [[ "$output" == *"unknown key: key_cmd"* ]]
}

@test "doctor: bad value shapes are errors" {
  write_config enabled=yes timeout_ms=fast base_url=http://gateway.example.com
  run judge_cmd doctor
  [ "$status" -eq 1 ]
  [[ "$output" == *"enabled must be true or false"* ]]
  [[ "$output" == *"timeout_ms must be a positive integer"* ]]
  [[ "$output" == *"base_url must be https"* ]]
}

@test "doctor: a key_file wider than 600 is an error and the key is not printed" {
  unset AI_GATEWAY_API_KEY
  mkdir -p "$HOME/.config/vaultmem"
  printf '%s\n' "$KEY_VALUE" >"$HOME/.config/vaultmem/ai-gateway.key"
  chmod 644 "$HOME/.config/vaultmem/ai-gateway.key"
  run judge_cmd doctor
  [ "$status" -eq 1 ]
  [[ "$output" == *"wider than 600"* ]]
  [[ "$output" != *"$KEY_VALUE"* ]]
}

@test "doctor: a missing key is an error when enabled, a note when disabled" {
  unset AI_GATEWAY_API_KEY
  run judge_cmd doctor
  [ "$status" -eq 1 ]
  write_config enabled=false
  run judge_cmd doctor
  [ "$status" -eq 0 ]
  [[ "$output" == *"note"*"no key"* ]]
}

@test "doctor: a judge file that does not parse, or has a bad type, is an error" {
  printf '{not json' >"$XDG_CONFIG_HOME/vaultmem/judges/broken.json"
  printf '{"version":1,"questions":{"q":{"type":"noul"}},"thresholds":{"zz":{"yes":2}}}' \
    >"$XDG_CONFIG_HOME/vaultmem/judges/badtype.json"
  run judge_cmd doctor
  [ "$status" -eq 1 ]
  [[ "$output" == *"broken.json: not valid JSON"* ]]
  [[ "$output" == *"badtype.json: question q: type must be boolean, choice, or score"* ]]
  [[ "$output" == *"badtype.json: thresholds.zz: no such question"* ]]
}

@test "doctor: config unavailable is an error" {
  VAULTMEM_BIN="$BATS_TEST_TMPDIR/bin/does-not-exist" run judge_cmd doctor
  [ "$status" -eq 1 ]
  [[ "$output" == *"config not available"* ]]
}

@test "doctor --live: prints the gateway error type and message, never the key" {
  FAKE_CURL_RESPONSE="$FIX/error-401.json" FAKE_CURL_HTTP=401 run judge_cmd doctor --live
  [ "$status" -eq 1 ]
  [[ "$output" == *"authentication_error: Authentication failed"* ]]
  [[ "$output" != *"$KEY_VALUE"* ]]
}

@test "doctor --live: refuses when the extension is disabled" {
  write_config enabled=false
  run judge_cmd doctor --live
  [ "$status" -eq 1 ]
  curl_not_invoked
}

# --- the groom-triage judge -----------------------------------------------------------

# The state a real `groom --judge` call sends: frontmatter, bookmark, pinned,
# git state, work-log tail, and the parent Project's decisions. Ages and counts
# arrive as plain text; the model never computes them.
groom_state() { cat "$FIX/groom-triage-state.txt"; }

@test "groom-triage: the request body matches the golden file" {
  FAKE_CURL_RESPONSE="$FIX/groom-triage-response.json" \
    run judge_in "$(groom_state)" groom-triage --vault personal --subject "Sessions/ad707-athlete-prepare/_index.md"
  [ "$status" -eq 0 ]
  diff <(jq -S . "$CURL_REC/body") <(jq -S . "$FIX/groom-triage-body.json")
  # The state fits the budget, so nothing was cut.
  [ "$(tail -n 1 "$LOG" | jq -r '.truncated')" = "false" ]
}

@test "groom-triage: the judge file ships with the four booleans and the choice" {
  run judge_cmd list
  printf '%s\n' "$output" | grep -q "^groom-triage	shipped	"
  local j="$ROOT/ext/judge/judges/groom-triage.json"
  [ "$(jq -r '[.questions | to_entries[] | select(.value.type == "boolean") | .key] | sort | join(",")' "$j")" = \
    "blocked_external,has_next_step,undistilled,work_complete" ]
  [ "$(jq -r '.questions.recommendation.type' "$j")" = "choice" ]
  [ "$(jq -r '[.questions.recommendation.criteria | keys[]] | sort | join(",")' "$j")" = \
    "archive,keep-active,needs-human,park" ]
  [ "$(jq -r '.truncate' "$j")" = "tail" ]
  [ "$(jq -r '.max_state_bytes' "$j")" = "24000" ]
  [ "$(jq -r '.thresholds.recommendation.min_confidence' "$j")" = "0.6" ]
  [ "$(jq -r '[.questions | to_entries[] | select(.value.type == "boolean")
               | "\(.value.criteria | has("true")) \(.value.criteria | has("false"))"] | unique | join("")' "$j")" = \
    "true true" ]
  # Every boolean is gated at the documented thresholds.
  [ "$(jq -r '[.thresholds | to_entries[] | select(.value | has("yes"))
               | "\(.value.yes)/\(.value.no)"] | unique | join(",")' "$j")" = "0.85/0.15" ]
}

@test "groom-triage: a canned response maps to the documented answer fields" {
  FAKE_CURL_RESPONSE="$FIX/groom-triage-response.json" \
    run judge_in "$(groom_state)" groom-triage --vault personal
  [ "$status" -eq 0 ]
  # The four booleans core reads by probability.
  [ "$(printf '%s' "$output" | jq -r '.answers.work_complete.probability')" = "0.04" ]
  [ "$(printf '%s' "$output" | jq -r '.answers.has_next_step.probability')" = "0.93" ]
  [ "$(printf '%s' "$output" | jq -r '.answers.blocked_external.probability')" = "0.88" ]
  [ "$(printf '%s' "$output" | jq -r '.answers.undistilled.probability')" = "0.91" ]
  # The choice core reads by .choice and .probabilities.<choice>.
  [ "$(printf '%s' "$output" | jq -r '.answers.recommendation.choice')" = "park" ]
  [ "$(printf '%s' "$output" | jq -r '.answers.recommendation.probabilities.park')" = "0.81" ]
  [ "$(printf '%s' "$output" | jq -r '.judge')" = "groom-triage" ]
  # The id on stdout keys `judge feedback` later.
  [ "$(printf '%s' "$output" | jq -r '.id')" = "$(jq -r '.id' "$LOG")" ]
}

@test "groom-triage: gating the recommendation maps confidence to exit codes" {
  FAKE_CURL_RESPONSE="$FIX/groom-triage-response.json" \
    run judge_in "$(groom_state)" groom-triage --vault personal --gate recommendation
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.gate.verdict')" = "yes" ]
  # Below min_confidence = 0.6 the caller gets "no opinion".
  FAKE_CURL_RESPONSE="$FIX/groom-triage-response-lowconf.json" \
    run judge_in "$(groom_state)" groom-triage --vault personal --gate recommendation
  [ "$status" -eq 2 ]
  [ "$(printf '%s' "$output" | jq -r '.gate.verdict')" = "abstain" ]
}

@test "groom-triage: state over max_state_bytes is cut tail-biased" {
  local big
  big="$(groom_state)$(printf 'x%.0s' $(seq 1 24000))TAIL-MARKER"
  FAKE_CURL_RESPONSE="$FIX/groom-triage-response.json" \
    run judge_in "$big" groom-triage --vault personal
  [ "$status" -eq 0 ]
  [ "$(jq -r '.state | length' "$CURL_REC/body")" -eq 24000 ]
  # tail-biased: the end survives, the head is gone.
  jq -r '.state' "$CURL_REC/body" | grep -q 'TAIL-MARKER'
  ! jq -r '.state' "$CURL_REC/body" | grep -q 'ad707-athlete-prepare'
  [ "$(tail -n 1 "$LOG" | jq -r '.truncated')" = "true" ]
}

# --- feedback ---------------------------------------------------------------------------

# seed_log <file> <line…>: write rows to the live log or the rotated generation.
seed_log() {
  local target="$1"
  shift
  mkdir -p "$(dirname "$LOG")"
  printf '%s\n' "$@" >"$target"
}

DEC_A='{"id":"dec-a","ts":"2026-09-20T10:00:00Z","judge":"groom-triage","vault":"personal","answers":{"recommendation":{"type":"choice","choice":"archive","probabilities":{"archive":0.91,"park":0.09}}},"feedback":null}'
DEC_B='{"id":"dec-b","ts":"2026-09-20T11:00:00Z","judge":"groom-triage","vault":"personal","answers":{"recommendation":{"type":"choice","choice":"park","probabilities":{"park":0.72,"archive":0.28}}},"feedback":null}'
DEC_C='{"id":"dec-c","ts":"2026-09-20T12:00:00Z","judge":"smoke","vault":"personal","answers":{"failed":{"type":"boolean","probability":0.88}},"feedback":null}'

@test "feedback: appends a row and never rewrites the existing ones" {
  seed_log "$LOG" "$DEC_A" "$DEC_B"
  local before
  before=$(cat "$LOG")
  run judge_cmd feedback dec-a right
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  # The original rows are byte-identical; the new row is appended after them.
  [ "$(head -n 2 "$LOG")" = "$before" ]
  [ "$(wc -l <"$LOG" | tr -d ' ')" -eq 3 ]
  [ "$(tail -n 1 "$LOG" | jq -r '[.id, .feedback] | @tsv')" = "dec-a	right" ]
  tail -n 1 "$LOG" | jq -e '.ts | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$")'
  # A feedback row carries no judge field, so it is never itself a decision.
  [ "$(tail -n 1 "$LOG" | jq -r 'has("judge")')" = "false" ]
  curl_not_invoked
}

@test "feedback: an unknown id exits 64 with one stderr line and appends nothing" {
  seed_log "$LOG" "$DEC_A"
  run judge_cmd feedback nosuch-id right
  [ "$status" -eq 64 ]
  [ -z "$output" ]
  [ "$(wc -l <"$STDERR" | tr -d ' ')" -eq 1 ]
  grep -q 'no decision row with id nosuch-id' "$STDERR"
  [ "$(wc -l <"$LOG" | tr -d ' ')" -eq 1 ]
  curl_not_invoked
}

@test "feedback: an id only in judge.jsonl.1 is found, and .1 is not rewritten" {
  seed_log "$LOG.1" "$DEC_A"
  seed_log "$LOG" "$DEC_B"
  local rotated_before
  rotated_before=$(cat "$LOG.1")
  run judge_cmd feedback dec-a wrong
  [ "$status" -eq 0 ]
  # The rotated file is untouched; the feedback row lands in the live file.
  [ "$(cat "$LOG.1")" = "$rotated_before" ]
  [ "$(tail -n 1 "$LOG" | jq -r '[.id, .feedback] | @tsv')" = "dec-a	wrong" ]
  [ "$(wc -l <"$LOG" | tr -d ' ')" -eq 2 ]
}

@test "feedback: feedback on a row that already has feedback appends again" {
  seed_log "$LOG" "$DEC_A"
  run judge_cmd feedback dec-a wrong
  [ "$status" -eq 0 ]
  run judge_cmd feedback dec-a right
  [ "$status" -eq 0 ]
  [ "$(wc -l <"$LOG" | tr -d ' ')" -eq 3 ]
  [ "$(jq -r 'select(has("judge") | not) | .feedback' "$LOG" | tr '\n' ' ')" = "wrong right " ]
  # The latest wins at read time: one row, counted right.
  run judge_cmd calibration
  printf '%s\n' "$output" | grep -q "^0.9-1.0	1	1	1$"
}

@test "feedback: a feedback row is not itself a feedbackable decision" {
  seed_log "$LOG" "$DEC_A"
  run judge_cmd feedback dec-a right
  [ "$status" -eq 0 ]
  # dec-a now has a feedback row; feedback on it still resolves to the decision.
  run judge_cmd feedback dec-a wrong
  [ "$status" -eq 0 ]
  # An id that exists only as a feedback row is still unknown.
  run judge_cmd feedback nosuch right
  [ "$status" -eq 64 ]
}

@test "feedback: works with enabled=false and never invokes curl" {
  write_config enabled=false
  seed_log "$LOG" "$DEC_A"
  run judge_cmd feedback dec-a right
  [ "$status" -eq 0 ]
  [ "$(tail -n 1 "$LOG" | jq -r '.feedback')" = "right" ]
  curl_not_invoked
}

@test "feedback: needs no config at all (the log is local data)" {
  seed_log "$LOG" "$DEC_A"
  VAULTMEM_BIN="$BATS_TEST_TMPDIR/bin/does-not-exist" run judge_cmd feedback dec-a right
  [ "$status" -eq 0 ]
  [ "$(tail -n 1 "$LOG" | jq -r '.feedback')" = "right" ]
  curl_not_invoked
}

@test "feedback: a rotation during the append is survived without failing" {
  seed_log "$LOG" "$DEC_A"
  VAULTMEM_JUDGE_LOG_MAX_BYTES=10 run judge_cmd feedback dec-a right
  [ "$status" -eq 0 ]
  # The decision row rotated out; the feedback row is alone in the live file.
  [ "$(jq -r '.id' "$LOG.1")" = "dec-a" ]
  [ "$(tail -n 1 "$LOG" | jq -r '[.id, .feedback] | @tsv')" = "dec-a	right" ]
  # Both sides still join: the pair survives the rotation boundary.
  run judge_cmd calibration
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -q "^0.9-1.0	1	1	1$"
}

# --- calibration --------------------------------------------------------------------------

@test "calibration: buckets a synthetic log by judged probability" {
  # One row per bucket, plus a second 0.9-1.0 row marked wrong so accuracy != 1.
  seed_log "$LOG" \
    '{"id":"p55","judge":"groom-triage","answers":{"recommendation":{"type":"choice","choice":"park","probabilities":{"park":0.55}}}}' \
    '{"id":"p65","judge":"groom-triage","answers":{"recommendation":{"type":"choice","choice":"park","probabilities":{"park":0.65}}}}' \
    '{"id":"p75","judge":"groom-triage","answers":{"recommendation":{"type":"choice","choice":"park","probabilities":{"park":0.75}}}}' \
    '{"id":"p85","judge":"groom-triage","answers":{"recommendation":{"type":"choice","choice":"park","probabilities":{"park":0.85}}}}' \
    '{"id":"p95","judge":"groom-triage","answers":{"recommendation":{"type":"choice","choice":"park","probabilities":{"park":0.95}}}}' \
    '{"id":"p97","judge":"groom-triage","answers":{"recommendation":{"type":"choice","choice":"park","probabilities":{"park":0.97}}}}'
  for id in p55 p65 p75 p85 p95; do
    run judge_cmd feedback "$id" right
    [ "$status" -eq 0 ]
  done
  run judge_cmd feedback p97 wrong
  [ "$status" -eq 0 ]

  run judge_cmd calibration
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "bucket	n	right	accuracy" ]
  [ "${lines[1]}" = "0.5-0.6	1	1	1" ]
  [ "${lines[2]}" = "0.6-0.7	1	1	1" ]
  [ "${lines[3]}" = "0.7-0.8	1	1	1" ]
  [ "${lines[4]}" = "0.8-0.9	1	1	1" ]
  [ "${lines[5]}" = "0.9-1.0	2	1	0.5" ]
  [ "${#lines[@]}" -eq 6 ]
  curl_not_invoked
}

@test "calibration: a decision with no feedback is not counted" {
  seed_log "$LOG" "$DEC_A" "$DEC_B"
  run judge_cmd feedback dec-a right
  run judge_cmd calibration
  [ "$status" -eq 0 ]
  # Only dec-a (0.91) appears. dec-b (0.72) has no feedback.
  [ "${#lines[@]}" -eq 2 ]
  [ "${lines[1]}" = "0.9-1.0	1	1	1" ]
}

@test "calibration: --judge filters to one judge" {
  seed_log "$LOG" "$DEC_A" "$DEC_C"
  run judge_cmd feedback dec-a right
  run judge_cmd feedback dec-c right
  run judge_cmd calibration
  [ "${#lines[@]}" -eq 3 ]
  run judge_cmd calibration --judge groom-triage
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 2 ]
  [ "${lines[1]}" = "0.9-1.0	1	1	1" ]
  run judge_cmd calibration --judge smoke
  [ "${#lines[@]}" -eq 2 ]
  # dec-c is a boolean judge: its probability is the one that gets bucketed.
  [ "${lines[1]}" = "0.8-0.9	1	1	1" ]
  run judge_cmd calibration --judge nosuchjudge
  [ "$status" -eq 0 ]
  [[ "$output" == *"no feedback rows yet"* ]]
}

@test "calibration: joins feedback to decisions across a rotation boundary" {
  seed_log "$LOG.1" "$DEC_A"
  seed_log "$LOG" "$DEC_B"
  run judge_cmd feedback dec-a right
  [ "$status" -eq 0 ]
  run judge_cmd feedback dec-b wrong
  [ "$status" -eq 0 ]
  run judge_cmd calibration
  [ "$status" -eq 0 ]
  # dec-a is in .1 at 0.91, dec-b is live at 0.72. Both join.
  [ "${lines[1]}" = "0.7-0.8	1	0	0" ]
  [ "${lines[2]}" = "0.9-1.0	1	1	1" ]
}

@test "calibration: no feedback rows prints one line and exits 0" {
  run judge_cmd calibration
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]
  [[ "$output" == *"no feedback rows yet"* ]]
  seed_log "$LOG" "$DEC_A"
  run judge_cmd calibration
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]
  [[ "$output" == *"no feedback rows yet"* ]]
  curl_not_invoked
}

@test "calibration: a probability below 0.5 falls in no bucket" {
  seed_log "$LOG" \
    '{"id":"low","judge":"groom-triage","answers":{"recommendation":{"type":"choice","choice":"park","probabilities":{"park":0.35}}}}'
  run judge_cmd feedback low right
  [ "$status" -eq 0 ]
  run judge_cmd calibration
  [ "$status" -eq 0 ]
  [[ "$output" == *"no feedback rows yet"* ]]
}

@test "calibration: --format json emits one object per bucket" {
  seed_log "$LOG" "$DEC_A" "$DEC_B"
  run judge_cmd feedback dec-a right
  run judge_cmd feedback dec-b wrong
  run judge_cmd calibration --format json
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -c 'map(.bucket)')" = '["0.7-0.8","0.9-1.0"]' ]
  [ "$(printf '%s' "$output" | jq -r '.[] | select(.bucket == "0.9-1.0") | [.n, .right, .accuracy] | @tsv')" = "1	1	1" ]
  [ "$(printf '%s' "$output" | jq -r '.[] | select(.bucket == "0.7-0.8") | [.n, .right, .accuracy] | @tsv')" = "1	0	0" ]
}

@test "calibration: works with enabled=false and with no config at all" {
  seed_log "$LOG" "$DEC_A"
  run judge_cmd feedback dec-a right
  write_config enabled=false
  run judge_cmd calibration
  [ "$status" -eq 0 ]
  [ "${lines[1]}" = "0.9-1.0	1	1	1" ]
  VAULTMEM_BIN="$BATS_TEST_TMPDIR/bin/does-not-exist" run judge_cmd calibration
  [ "$status" -eq 0 ]
  [ "${lines[1]}" = "0.9-1.0	1	1	1" ]
  curl_not_invoked
}

# --- the shell floor -----------------------------------------------------------------

@test "the extension runs under /bin/bash when that is bash 3.2" {
  /bin/bash --version 2>/dev/null | head -n 1 | grep -q 'version 3\.2' || skip "/bin/bash is not 3.2 here"
  JUDGE_SH=/bin/bash
  run judge_in "$STATE_TEXT" smoke --vault personal --gate failed
  [ "$status" -eq 0 ]
  [ ! -s "$STDERR" ]
  diff <(jq -S . "$CURL_REC/body") <(jq -S . "$FIX/smoke-body-zdr.json")
}
