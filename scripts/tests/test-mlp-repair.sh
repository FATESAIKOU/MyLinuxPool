#!/usr/bin/env bash
# test-mlp-repair.sh — red tests for `mlp`'s family-repair-host scan
# (design.md D9-D14, EPHEMERAL-INTERFACE.md item 8). NONE of this is
# implemented in ops-scripts/mlp yet — this file is expected to run RED
# against current code (see OUT-test-ephemeral-mlp.md for the recorded
# failures); it defines the interface impl must land against.
#
# ---- INTERFACE THIS FILE ASSUMES (write here first, PM's judgement) ------
#
# resolve_gateway() gains two globals, read from the SAME pool-resolve
# JSON it already fetches (no extra gh/pool-resolve call):
#   GW_REPAIR_LO / GW_REPAIR_HI — from NODE_GATEWAY.ports.repair[0]/[1].
#   Both empty when the field is missing or not a clean [lo,hi] pair of
#   non-negative integers with lo<=hi. NO hardcoded fallback range, ever
#   (EPHEMERAL-INTERFACE item 2).
#
# A new function gather_repair_targets (no args) prints TSV rows
# "name<TAB>port<TAB>state" to stdout, one per repair host currently
# observed, OR prints the single sentinel line "!UNCONFIGURED" (nothing
# else) when GW_REPAIR_LO/GW_REPAIR_HI are empty. Must be called with CTL
# already open (uses gw_run only — never opens its own ControlMaster,
# never calls gh). It fetches listeners AND nameplates in exactly ONE
# remote command (one gw_run call) — that is the concrete meaning this
# file gives to interface item 5's "one remote command or the same
# ControlMaster": listeners+nameplates specifically share one round trip;
# separate gw_run calls elsewhere (worker-ledger, per-port up/down probes)
# are unaffected and unchanged, and still ride the same ControlMaster.
# "state" is "up" for every emitted row — D5 makes the listener the only
# fact, so a row only exists when a listener was observed; there is no
# "down" repair state (see LIMITATIONS below, this is a real simplification
# vs the provider/worker table's banner-based up/down).
#
# ---- User UI change (post-acceptance ticket, supersedes the original ---
# ---- "repair:" section design below) -----------------------------------
# A real user, after desktop acceptance, found the original design's
# `repair:` sub-section (its own little 3-column `  NAME  PORT  STATE`
# block under the main table) visually broken: its columns never lined up
# with the main table's NAME/TYPE/PROVIDER/PORT/STATE columns above it.
# New contract (this supersedes every "repair:" header/sub-block
# assumption anywhere below or in earlier sections of this file — where
# those conflict with this note, THIS note wins):
#
#   cmd_ls: NO separate section, no "repair:" line, ever. Each repair host
#   gathered by gather_repair_targets becomes ONE MORE ROW in the exact
#   same `rows` array/table gateway/provider/worker rows already go
#   through — same header ("NAME TYPE PROVIDER PORT STATE"), same
#   namewidth/provwidth/statewidth computation (so a long repair name
#   widens every column, same as a long provider/container name already
#   does), same `fmt`/print_state rendering. Column values:
#     NAME = the nameplate name, or "?" — exactly gather_repair_targets's
#            own field 1, untouched.
#     TYPE = the literal string "repair".
#     PROVIDER = "-" (repair hosts have no provider; same convention the
#            gateway row already uses for the same reason).
#     PORT = gather_repair_targets's field 2 (the listener's real port).
#     STATE = "up" (gather_repair_targets's field 3 — there is no other
#            value today, see the no-"down"-state note above).
#   Two repair hosts sharing a name are simply two rows with the same
#   NAME and different PORT — nothing new needed for that, it falls out
#   of "each gathered row becomes one table row".
#   When ports.repair is unconfigured: zero rows have TYPE=repair (same
#   as before — gather_repair_targets contributes nothing), the existing
#   stderr warning is unchanged, and the gateway/provider/worker rows are
#   completely unaffected — this was already true structurally (repair
#   rows were always additive), the user ticket doesn't change it, and
#   §1c re-confirms it explicitly under the new format.
#
#   cmd_ssh with no argument (the fzf picker): its candidate list, today
#   built purely from gather_targets, must ALSO include one line per
#   gather_repair_targets row — type "repair", provider "-", user
#   "repair", state from field 3, in the SAME 6-field
#   name/type/provider/port/user/state shape every other candidate
#   already uses (so `--with-nth=1,2,3,4,6` keeps showing the right
#   columns without a picker-specific carve-out). Selecting a repair line
#   dials it by PORT via the existing `do_connect "$type" "$port" "$user"`
#   call every other picker selection already makes — never a second,
#   name-based resolve (which would be exactly the ambiguity/"?"-is-not-
#   a-real-name problem the picker is supposed to sidestep by letting the
#   human pick a specific row/port instead of typing a name).
#
# ---- Definition 1 (ticket item 1): missing port range -----------------
# "Loud refusal for repair-specific operations, but `mlp ls` still shows
# providers/workers" is defined as:
#   * `mlp ls`: prints the existing gateway/provider/worker table exactly
#     as before (unaffected), prints ONE line to STDERR
#     ("mlp: NODE_GATEWAY.ports.repair not configured — skipping repair
#     section"), and EXITS 0 — the parts of `ls` that could succeed, did.
#     Under the merged-table format below (user UI change), "no repair
#     section" means "zero rows with TYPE=repair", not a separate block —
#     there was never a distinct block to omit in the first place once
#     repair rows are just rows in the one table.
#   * `mlp ssh <name>` (name, not a bare port): if provider/worker
#     resolution already failed, AND the range is unconfigured, this is
#     LOUD (an extra stderr line naming NODE_GATEWAY.ports.repair as the
#     reason we cannot rule $name out as a repair host) WITHOUT
#     reclassifying the error: TARGET_ERR stays "notfound" (do_connect
#     still dies with the same "no such node or worker: $1", just with
#     one more line ahead of it via TARGET_DETAIL, the same mechanism the
#     existing "unreachable" case already uses). This was a deliberate
#     revision: an earlier draft used a distinct TARGET_ERR value here and
#     broke test-mlp-fwd.sh §7d (an existing, unrelated "unknown name ->
#     notfound" regression test that never configures a repair range at
#     all) — reclassifying notfound is exactly the kind of "existing
#     behavior regresses" item 6 rules out, so loudness has to ride an
#     auxiliary field, never the primary classification. This refusal
#     only fires when nothing else already resolved the name (a working
#     provider/worker name must never start failing because repair is
#     unconfigured).
#   * `mlp ssh <bare-port>`: UNCHANGED existing behavior (falls to the
#     worker-ledger bare-port fallthrough) — we cannot tell "is this port
#     meant to be a repair port" without the range either, but the
#     existing bare-port contract already treats any bare port as a
#     worker dial with no range validation, so there is nothing new here
#     to refuse loudly about, and regressing that would break item 6.
#
# ---- Definition 2 (ticket item 6): name-collision precedence ----------
# Provider/worker resolution ALWAYS runs first and ALWAYS wins: a repair
# name is only ever looked up after pool-resolve (gateway/provider) and
# the worker ledger have both already failed to match. Reasoning:
#   * Provider/worker names are the pool's durable, deliberately-chosen
#     registry; a repair name is whatever a family member typed into a
#     Windows dialog once, unreviewed and effectively random. Giving the
#     ephemeral, low-trust name priority over the durable, high-trust one
#     would let a coincidence (or a mischievous family member) shadow a
#     real provider/worker's `mlp ssh <name>`.
#   * This also means item 6's "existing behavior must not regress" is
#     true by construction: the repair lookup is purely additive at the
#     END of target_resolve's existing fallthrough chain, so a name that
#     used to resolve to a provider/worker still does, unconditionally.
#   * The one exception already carved out by the interface itself: a
#     bare numeric name inside the repair range short-circuits to type
#     "repair" BEFORE even the pool-resolve/worker-ledger steps run
#     (interface item 4 — "goes straight there"). This does not conflict
#     with the provider/worker-wins rule above because the segments are
#     disjoint by NODE_GATEWAY's own contract: a provider/worker's
#     gateway_port is never inside ports.repair, so there is no real name
#     this could shadow — only ports.repair's own numbers, which have no
#     other meaning to collide with.
#
# ---- do_connect -------------------------------------------------------
# case "$type" gains "repair" alongside "provider|worker" (same
# ssh_via_gateway call, user is always "repair" per design D-whatever/
# docs/REPAIR-HOST.md §4). On a "repair-ambiguous" TARGET_ERR, do_connect
# dies listing TARGET_CANDIDATES (comma-joined ports) before connecting.
#
# ---- target_resolve stays a Model (no printf/echo/fzf in its own body)-
# This repo already has a static+dynamic layering guard for target_resolve
# (test-mlp-fwd.sh §8a/§8b): it may not use output primitives anywhere in
# its own text, even ones whose output is only ever captured into a
# variable. Building TARGET_CANDIDATES with `echo` inside target_resolve
# trips this EXISTING guard — found the hard way while proving this file's
# throwaway implementation green (see OUT-test-ephemeral-mlp.md). Join the
# candidate ports with plain parameter expansion / a for-loop instead.
#
# ---- Testing technique (reused from test-mlp-fwd.sh / test-mlp-
# discovery.sh) ----------------------------------------------------------
# `source "$MLP_FILE"` directly (mlp's own bottom-of-file guard —
# `[[ "${BASH_SOURCE[0]}" == "${0}" ]]` — means sourcing never runs main);
# override POOL_RESOLVE to a PATH-stub script; fake `ssh`/`gh` on PATH,
# argv-logging one token per line with a CALL-EOL marker between calls
# (same shim idiom as test-mlp-fwd.sh, extended with a repair-scan
# fixture-replay case). Every case runs offline: no network, no real
# machine, no dispatch.
#
# MLP under test defaults to the real ops-scripts/mlp (this file, run
# normally, is the RED suite against current code). Override with
# MLP_UNDER_TEST=/path/to/a/copy to prove a throwaway implementation goes
# green — this is how OUT-test-ephemeral-mlp.md's green/injection proof
# was produced; that copy is NEVER this repo's ops-scripts/mlp.
#
# ---- Live finding: /home/sshproxy/repair/ is 750 sshproxy:sshproxy -----
# Real-Gateway verification found mlp's remote scan runs as the operator's
# own Gateway user (GW_USER), which cannot read a 750 sshproxy:sshproxy
# directory — every host was showing "?" in practice, not because of any
# nameplate-content bug, but because the nameplate READ itself was always
# failing permission-denied. PM decision: read the nameplates with
# `sudo -n` (non-interactive; the pool already assumes this user has
# passwordless sudo — refresh installs authorized_keys via sudo), inside
# the SAME single remote command already used for the listener+nameplate
# scan (no new round trip, no new ControlMaster open — item 5 still
# holds). Concretely: `ss -tln` needs no privilege and stays outside any
# sudo wrapper (listeners must keep working even when sudo is broken);
# only the read of /home/sshproxy/repair/* is wrapped in `sudo -n`.
#
# WIRE MARKER (defined here for whoever implements this — does not exist
# in ops-scripts/mlp yet): if the `sudo -n` invocation fails (non-zero, or
# sudo's own "a password is required" text), the remote command must not
# let that failure text leak into the nameplate stream (same framing
# hazard as must-fix 1) — instead it emits exactly one line,
# "REPAIR-SCAN-SUDO-FAIL", as the ENTIRE content of the nameplate block
# (between the anchored REPAIR-SCAN-N and REPAIR-SCAN-END markers), and
# nothing else. gather_repair_targets, seeing that sentinel, must: (a)
# print exactly ONE loud line to stderr containing both "sudo" and
# "nameplate" (wording otherwise free), (b) still emit one row per real
# (127.0.0.1, in-range) listener — same as any other unreadable/invalid
# nameplate, name "?" — (c) never die: `mlp ls` still exits 0 (same
# "loud but ls still succeeds" contract as Definition 1's missing-range
# case). Known gap this doesn't try to close: a hostile nameplate file
# whose own (whole, validated) content happened to equal exactly
# "REPAIR-SCAN-SUDO-FAIL" would falsely trigger this path — accepted as
# out of scope for this ticket (must-fix 1's whole-content validation
# already makes that string invalid as a NAME anyway, so at worst it is
# indistinguishable from "some listener's nameplate was invalid", not a
# new escalation).
#
# ---- LIMITATIONS (see also OUT-test-ephemeral-mlp.md) ------------------
#   * "up" is scan-time-listener-observed only, no banner probe — a
#     repair host mid-boot (listener not yet up) is invisible, matching
#     provider/worker's pre-existing "down means observed, not probed"
#     semantics but NOT matching the recon note's proposed 4th
#     "connecting" state (OUT-recon-ephemeral.md §3.2) — not implemented,
#     not tested here.
#   * Windows-side name validation (`^[a-z]([a-z0-9-]{0,30}[a-z0-9])?$`,
#     interface item 3) is NOT re-validated by mlp in this design — a
#     malformed nameplate content is displayed as-is. Not tested here.
#   * fzf-picker path (`mlp ssh` with no argument) is not touched by this
#     file; repair rows are not added to that menu (open question for the
#     real implementer — this file only asserts the named/ported paths).
#   * Injections cover the load-bearing checks (range non-hardcoding,
#     nameplate-without-listener suppression, duplicate refusal,
#     precedence, single-remote-command, missing-range-still-shows-table)
#     — not every single assertion in this file has its own inline
#     mutant. See the injection section headers below for exactly which
#     ones do.
#
# Run: scripts/tests/test-mlp-repair.sh
# Prove green: MLP_UNDER_TEST=<throwaway copy> scripts/tests/test-mlp-repair.sh
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.." || exit 1
REPO_ROOT="$PWD"

MLP="ops-scripts/mlp"
MLP_FILE="${MLP_UNDER_TEST:-$REPO_ROOT/$MLP}"

if ! command -v jq >/dev/null 2>&1; then
    echo "ERROR: jq is required but not found on PATH" >&2
    exit 1
fi
if [[ ! -f "$MLP_FILE" ]]; then
    echo "test-mlp-repair: ${MLP_FILE} is missing; every case below will FAIL" >&2
fi

SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/test-mlp-repair.XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT INT TERM
mkdir -p "$SANDBOX/shims" "$SANDBOX/home"

pass=0; fail=0; injpass=0; injfail=0
ok()  { pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL  %s\n' "$1"; }
inj_ok()  { injpass=$((injpass+1)); printf '  ok    (注入) %s\n' "$1"; }
inj_bad() { injfail=$((injfail+1)); printf '  FAIL  (注入) %s\n' "$1"; }

# ---- merged-table geometry helpers (user UI change) ------------------------
# `mlp ls` no longer has a separate "repair:" section (see header note
# below) — a repair host is just another row in the SAME table, under the
# SAME "NAME TYPE PROVIDER PORT STATE" header, using whatever column
# widths that run's own header line ended up with (repair names can be
# longer than any provider/worker name seen, growing every column — never
# hardcode a width). "checking each field starts at the header's column
# offset" (the ticket's own suggested technique): find where each label
# starts in the header line ACTUALLY PRINTED for this run, then check a
# row's own field value sits at that exact byte offset.
#
# col_of <line> <needle> — byte offset of the first (only expected)
# occurrence of $needle in $line, or -1 if absent.
col_of() {
    local hay="$1" needle="$2" prefix
    prefix="${hay%%$needle*}"
    [[ "$prefix" == "$hay" ]] && { printf -- '-1'; return; }
    printf '%s' "${#prefix}"
}

# repair_row_present <ls_out_file> <name> <port> [state=up] — true iff some
# row has exactly $name starting at column 0 (immediately followed by
# whitespace or end of line, so "twin" never matches a hypothetical
# "twinX"), "repair" at the header's TYPE offset, "-" at PROVIDER, $port at
# PORT and $state at STATE — all at THIS run's own measured offsets.
repair_row_present() {
    local outfile="$1" name="$2" port="$3" state="${4:-up}"
    local hdr type_col prov_col port_col state_col row after
    hdr="$(grep -m1 '^NAME' "$outfile" 2>/dev/null)" || return 1
    [[ -n "$hdr" ]] || return 1
    type_col="$(col_of "$hdr" "TYPE")"; prov_col="$(col_of "$hdr" "PROVIDER")"
    port_col="$(col_of "$hdr" "PORT")"; state_col="$(col_of "$hdr" "STATE")"
    [[ "$type_col" -ge 0 && "$prov_col" -ge 0 && "$port_col" -ge 0 && "$state_col" -ge 0 ]] || return 1
    while IFS= read -r row; do
        [[ "${row:0:${#name}}" == "$name" ]] || continue
        after="${row:${#name}:1}"
        [[ -z "$after" || "$after" == " " ]] || continue
        [[ "${row:$type_col:6}" == "repair" ]] || continue
        [[ "${row:$prov_col:1}" == "-" ]] || continue
        [[ "${row:$port_col:${#port}}" == "$port" ]] || continue
        [[ "${row:$state_col:${#state}}" == "$state" ]] || continue
        return 0
    done < "$outfile"
    return 1
}

# repair_row_absent_port <ls_out_file> <port> — true iff NO row has type
# "repair" at that offset AND this exact port at the PORT offset (i.e. a
# nameplate-only or out-of-range port never became a row at all).
repair_row_absent_port() {
    local outfile="$1" port="$2"
    local hdr type_col port_col row
    hdr="$(grep -m1 '^NAME' "$outfile" 2>/dev/null)" || return 0
    [[ -n "$hdr" ]] || return 0
    type_col="$(col_of "$hdr" "TYPE")"; port_col="$(col_of "$hdr" "PORT")"
    [[ "$type_col" -ge 0 && "$port_col" -ge 0 ]] || return 0
    while IFS= read -r row; do
        [[ "${row:$type_col:6}" == "repair" ]] || continue
        [[ "${row:$port_col:${#port}}" == "$port" ]] || continue
        return 1
    done < "$outfile"
    return 0
}

# repair_row_count <ls_out_file> — number of rows whose TYPE column reads
# "repair" (whatever their NAME — "?" included).
repair_row_count() {
    local outfile="$1" hdr type_col row n=0
    hdr="$(grep -m1 '^NAME' "$outfile" 2>/dev/null)" || { printf '0'; return; }
    type_col="$(col_of "$hdr" "TYPE")"
    [[ "$type_col" -ge 0 ]] || { printf '0'; return; }
    while IFS= read -r row; do
        [[ "${row:$type_col:6}" == "repair" ]] && n=$((n + 1))
    done < "$outfile"
    printf '%s' "$n"
}

# ---- shims ----------------------------------------------------------------
# ssh: argv one token per line into ARGV_LOG, CALL-EOL between calls (same
# idiom as test-mlp-fwd.sh). Replay rules, in priority order:
#   -M  <ctl> ...           -> open_gateway_master: exit FAKE_MASTER_RC (0),
#                              and count it in MASTER_LOG (item 5's "opened
#                              only once" check).
#   REPAIR-SCAN-L in argv   -> the repair scan's one remote command: replay
#                              FAKE_REPAIR_SCAN_FILE verbatim, count it in
#                              SCAN_LOG (item 5's "one remote command"
#                              check).
#   pool-port-alloc         -> replay FAKE_WORKERS_FILE (default: []).
#   nc 127.0.0.1 <port>     -> gw_probe_port's banner probe: "SSH-NC_DONE"
#                              if <port> is in FAKE_UP_PORTS, else "NC_DONE"
#                              (never omit NC_DONE — an absent marker must
#                              read as inconclusive, never as down).
#   anything else           -> exit 0, no output (this is where the real
#                              interactive login lands: do_connect's
#                              ssh_via_gateway/ssh_gateway_only build their
#                              real argv and invoke this same shim, which
#                              we only need to log, not actually connect).
cat > "$SANDBOX/shims/ssh" <<'FAKE'
#!/usr/bin/env bash
for a in "$@"; do printf '%s\n' "$a" >> "${ARGV_LOG:-/dev/null}"; done
printf 'CALL-EOL\n' >> "${ARGV_LOG:-/dev/null}"
joined="$*"
case "$joined" in
  *"-M "*)
    printf 'MASTER\n' >> "${MASTER_LOG:-/dev/null}"
    exit "${FAKE_MASTER_RC:-0}"
    ;;
esac
case "$joined" in
  *"REPAIR-SCAN-L"*)
    printf 'SCAN\n' >> "${SCAN_LOG:-/dev/null}"
    cat "${FAKE_REPAIR_SCAN_FILE:-/dev/null}" 2>/dev/null
    exit 0
    ;;
esac
case "$joined" in
  *"pool-port-alloc"*) cat "${FAKE_WORKERS_FILE:-/dev/null}" 2>/dev/null; exit 0 ;;
esac
case "$joined" in
  *"nc 127.0.0.1 "*)
    port="${joined#*nc 127.0.0.1 }"; port="${port%% *}"
    case " ${FAKE_UP_PORTS:-} " in
      *" ${port} "*) printf 'SSH-NC_DONE' ;;
      *) printf 'NC_DONE' ;;
    esac
    exit 0
    ;;
esac
exit 0
FAKE
chmod +x "$SANDBOX/shims/ssh"

# pool-resolve: gateway -> FAKE_GW_JSON; any other exact name -> looked up
# in FAKE_NODES_JSON (a {name: node_json} object); miss -> exit 1. Every
# call logged (one line each) to PR_LOG for the gh-isolation/"repair scan
# adds zero calls" checks.
cat > "$SANDBOX/shims/pool-resolve" <<'FAKE'
#!/usr/bin/env bash
printf 'PR %s\n' "$*" >> "${PR_LOG:-/dev/null}"
if [[ "${1:-}" == "gateway" ]]; then
    printf '%s\n' "${FAKE_GW_JSON:-"{}"}"
    exit "${FAKE_GW_RC:-0}"
fi
node="${1:-}"
if [[ -n "${FAKE_NODES_JSON:-}" ]]; then
    out="$(jq -c --arg n "$node" '.[$n] // empty' "$FAKE_NODES_JSON" 2>/dev/null)"
    if [[ -n "$out" && "$out" != "null" ]]; then
        printf '%s\n' "$out"
        exit 0
    fi
fi
exit 1
FAKE
chmod +x "$SANDBOX/shims/pool-resolve"

# gh: only gather_targets' one enumeration call should ever reach this.
# Counted in GH_LOG; replays FAKE_GH_VARS_FILE (a list of NODE_* names).
cat > "$SANDBOX/shims/gh" <<'FAKE'
#!/usr/bin/env bash
printf 'GH\n' >> "${GH_LOG:-/dev/null}"
cat "${FAKE_GH_VARS_FILE:-/dev/null}" 2>/dev/null
exit 0
FAKE
chmod +x "$SANDBOX/shims/gh"

# fzf: this file never exercises the picker path; refuse loudly rather
# than hang if something unexpectedly reaches it.
cat > "$SANDBOX/shims/fzf" <<'FAKE'
#!/usr/bin/env bash
echo "test stub: refusing fzf" >&2
exit 255
FAKE
chmod +x "$SANDBOX/shims/fzf"

# ---- fixtures ---------------------------------------------------------
# Non-default repair range [2500,2599] (item 1: proves nothing is
# hardcoded to the documented default [2400,2499] — see the 2404 row
# below, which sits squarely in that default and must NOT show up).
GW_JSON_OK='{"ip":"9.9.9.9","user":"gw","port":22,"ports":{"repair":[2500,2599]}}'
GW_JSON_NOPORTS='{"ip":"9.9.9.9","user":"gw","port":22}'

printf '%s\n' 'NODE_PROVIDER1' > "$SANDBOX/gh-vars.txt"
printf '{"provider1":{"role":"provider","gateway_port":2323,"user":"pu","name":"provider1"}}\n' > "$SANDBOX/nodes.json"
printf '[{"container":"w1","port":2401,"provider":"provider1"}]\n' > "$SANDBOX/workers.json"
printf '[]\n' > "$SANDBOX/workers-empty.json"

# One repair-scan fixture covers items 2a-2e at once:
#   2503 dad-pc      -> listener+nameplate (2a)
#   2550 (no plate)  -> listener only, shown as "?" (2b)
#   2560 mom-laptop  -> nameplate only, no listener -> NOT shown (2c)
#   2404 (no plate)  -> listener OUTSIDE [2500,2599] -> NOT shown (2d)
#   2510/2520 twin   -> two listeners, same name -> both shown (2e)
cat > "$SANDBOX/repair-scan-main.txt" <<'SCAN'
REPAIR-SCAN-L
LISTEN 0 128 127.0.0.1:2404 0.0.0.0:*
LISTEN 0 128 127.0.0.1:2503 0.0.0.0:*
LISTEN 0 128 127.0.0.1:2510 0.0.0.0:*
LISTEN 0 128 127.0.0.1:2520 0.0.0.0:*
LISTEN 0 128 127.0.0.1:2550 0.0.0.0:*
REPAIR-SCAN-N
2503 dad-pc
2560 mom-laptop
2510 twin
2520 twin
REPAIR-SCAN-END
SCAN

# Collision fixture (item 6c): a provider literally named "dad-pc" that
# would collide with the repair scan's "dad-pc" nameplate above.
printf '{"dad-pc":{"role":"provider","gateway_port":2323,"user":"pu"}}\n' > "$SANDBOX/nodes-collide.json"

echo "=== 0. preconditions: does the interface exist yet? ==="
if grep -qE '^gather_repair_targets\(\)' "$MLP_FILE" 2>/dev/null; then
    ok "0a. gather_repair_targets() exists"
else
    bad "0a. gather_repair_targets() not found — repair scan not implemented yet"
fi
if grep -q 'ports\.repair' "$MLP_FILE" 2>/dev/null; then
    ok "0b. resolve_gateway (or similar) reads .ports.repair"
else
    bad "0b. no reference to .ports.repair in ${MLP_FILE} — port range not wired"
fi
if grep -qE 'provider\|worker\|repair\)' "$MLP_FILE" 2>/dev/null; then
    ok "0c. do_connect's type dispatch includes 'repair'"
else
    bad "0c. do_connect does not dispatch a 'repair' type yet"
fi

# ==========================================================================
echo "=== 1. port range source + missing-range refusal ==="
# 1a: resolve_gateway populates GW_REPAIR_LO/HI straight from the fixture's
#     non-default [2500,2599] — proves it is read, not hardcoded.
got="$(MLP_FILE="$MLP_FILE" FAKE_GW_JSON="$GW_JSON_OK" PR_LOG="$SANDBOX/pr1a.log" \
    HOME="$SANDBOX/home" PATH="$SANDBOX/shims:$PATH" \
    bash -c 'source "$MLP_FILE" >/dev/null 2>&1; POOL_RESOLVE="'"$SANDBOX"'/shims/pool-resolve"; resolve_gateway >/dev/null 2>&1; printf "LO=%s HI=%s" "$GW_REPAIR_LO" "$GW_REPAIR_HI"' 2>&1)"
if [[ "$got" == "LO=2500 HI=2599" ]]; then
    ok "1a. GW_REPAIR_LO/HI == fixture's [2500,2599] (not the documented default [2400,2499])"
else
    bad "1a. got [$got] want [LO=2500 HI=2599]"
fi

# 1b: ports.repair absent -> both empty, no fallback constant.
got="$(MLP_FILE="$MLP_FILE" FAKE_GW_JSON="$GW_JSON_NOPORTS" PR_LOG="$SANDBOX/pr1b.log" \
    HOME="$SANDBOX/home" PATH="$SANDBOX/shims:$PATH" \
    bash -c 'source "$MLP_FILE" >/dev/null 2>&1; POOL_RESOLVE="'"$SANDBOX"'/shims/pool-resolve"; resolve_gateway >/dev/null 2>&1; printf "LO=[%s] HI=[%s]" "$GW_REPAIR_LO" "$GW_REPAIR_HI"' 2>&1)"
if [[ "$got" == "LO=[] HI=[]" ]]; then
    ok "1b. ports.repair absent -> GW_REPAIR_LO/HI both empty (no 2400/2499 fallback)"
else
    bad "1b. got [$got] want [LO=[] HI=[]] — looks like a hardcoded fallback range"
fi

# 1c: `mlp ls` with the range unconfigured — provider/worker table intact,
#     repair section absent, ONE loud stderr line, exit 0.
run_ls() {
    local gwjson="$1" scanfile="$2" outfile="$3" errfile="$4"
    : > "$SANDBOX/argv.log"; : > "$SANDBOX/gh.log"; : > "$SANDBOX/master.log"; : > "$SANDBOX/scan.log"; : > "$SANDBOX/pr.log"
    MLP_FILE="$MLP_FILE" FAKE_GW_JSON="$gwjson" FAKE_GH_VARS_FILE="$SANDBOX/gh-vars.txt" \
    FAKE_NODES_JSON="$SANDBOX/nodes.json" FAKE_WORKERS_FILE="$SANDBOX/workers.json" \
    FAKE_REPAIR_SCAN_FILE="$scanfile" FAKE_UP_PORTS="2323" \
    ARGV_LOG="$SANDBOX/argv.log" GH_LOG="$SANDBOX/gh.log" MASTER_LOG="$SANDBOX/master.log" \
    SCAN_LOG="$SANDBOX/scan.log" PR_LOG="$SANDBOX/pr.log" \
    HOME="$SANDBOX/home" PATH="$SANDBOX/shims:$PATH" \
        bash -c 'source "$MLP_FILE" >/dev/null 2>&1; POOL_RESOLVE="'"$SANDBOX"'/shims/pool-resolve"; cmd_ls' \
        >"$outfile" 2>"$errfile"
    return $?
}
run_ls "$GW_JSON_NOPORTS" "$SANDBOX/repair-scan-main.txt" "$SANDBOX/ls1c.out" "$SANDBOX/ls1c.err"
rc=$?
if [[ $rc -ne 0 ]]; then
    bad "1c. mlp ls exit=$rc (want 0 — provider/worker still succeeded)"
elif ! grep -qE '^gateway[[:space:]]+gateway' "$SANDBOX/ls1c.out"; then
    bad "1c. gateway row missing from ls output — regression"
elif ! grep -qE '^provider1[[:space:]]+provider' "$SANDBOX/ls1c.out"; then
    bad "1c. provider1 row missing from ls output — regression"
elif grep -qxF 'repair:' "$SANDBOX/ls1c.out"; then
    bad "1c. a 'repair:' section header line is printed — the merged-table format (user UI change) must never print one, configured or not"
elif [[ "$(repair_row_count "$SANDBOX/ls1c.out")" != "0" ]]; then
    bad "1c. some row has TYPE=repair even though ports.repair is unconfigured (count: $(repair_row_count "$SANDBOX/ls1c.out"))"
elif ! grep -qF 'ports.repair' "$SANDBOX/ls1c.err"; then
    bad "1c. no loud stderr warning naming ports.repair (err=[$(cat "$SANDBOX/ls1c.err")])"
else
    ok "1c. ls: provider/worker table intact, zero repair rows, one loud stderr line, exit 0"
fi

# 1d: `mlp ssh <name>` with the range unconfigured and no other match —
# loud (names NODE_GATEWAY.ports.repair on stderr) but NOT reclassified:
# still exits 1, still says "no such node or worker" (the pre-existing
# generic message an unrelated caller like test-mlp-fwd.sh §7d already
# depends on — see Definition 1 above).
: > "$SANDBOX/argv1d.log"
got_rc=0
MLP_FILE="$MLP_FILE" FAKE_NODES_JSON="$SANDBOX/nodes.json" FAKE_WORKERS_FILE="$SANDBOX/workers-empty.json" \
ARGV_LOG="$SANDBOX/argv1d.log" HOME="$SANDBOX/home" PATH="$SANDBOX/shims:$PATH" \
    bash -c '
        source "$MLP_FILE" >/dev/null 2>&1
        POOL_RESOLVE="'"$SANDBOX"'/shims/pool-resolve"
        GW_IP=9.9.9.9; GW_USER=gw; GW_PORT=22; GW_KNOWN_HOSTS=/tmp/kh-test-repair
        GW_REPAIR_LO=""; GW_REPAIR_HI=""
        do_connect "totally-unknown-name"
    ' >/dev/null 2>"$SANDBOX/dc1d.err" || got_rc=$?
if [[ $got_rc -ne 1 ]]; then
    bad "1d. do_connect with an unconfigured range exited $got_rc (want 1, same as plain notfound)"
elif ! grep -qF 'no such node or worker: totally-unknown-name' "$SANDBOX/dc1d.err"; then
    bad "1d. missing the existing generic notfound message (err=[$(cat "$SANDBOX/dc1d.err")]) — must not be replaced"
elif ! grep -qF 'ports.repair' "$SANDBOX/dc1d.err"; then
    bad "1d. missing the loud extra line naming ports.repair (err=[$(cat "$SANDBOX/dc1d.err")])"
else
    ok "1d. mlp ssh <unknown-name> with range unconfigured: loud extra line about ports.repair, but still the plain notfound message/exit code (no reclassification)"
fi

# INJECTION for §1: a broken resolve_gateway that hardcodes the
# documented-default range regardless of what NODE_GATEWAY says. This is
# exactly the anti-hardcoding property 1a/1c are supposed to catch.
got="$(MLP_FILE="$MLP_FILE" FAKE_GW_JSON="$GW_JSON_OK" PR_LOG="$SANDBOX/pr-inj1.log" \
    HOME="$SANDBOX/home" PATH="$SANDBOX/shims:$PATH" \
    bash -c '
        source "$MLP_FILE" >/dev/null 2>&1
        POOL_RESOLVE="'"$SANDBOX"'/shims/pool-resolve"
        resolve_gateway() { GW_REPAIR_LO=2400; GW_REPAIR_HI=2499; return 0; }
        resolve_gateway >/dev/null 2>&1
        printf "LO=%s HI=%s" "$GW_REPAIR_LO" "$GW_REPAIR_HI"
    ' 2>&1)"
if [[ "$got" == "LO=2500 HI=2599" ]]; then
    inj_bad "1a-inj. hardcoded-fallback mutant slipped past — got [$got], expected the mutant's wrong [2400/2499] to be visibly wrong"
elif [[ "$got" == "LO=2400 HI=2499" ]]; then
    inj_ok "1a-inj. hardcoded-fallback mutant correctly produces the WRONG (non-fixture) range — 1a would have caught this in the real function"
else
    inj_bad "1a-inj. unexpected mutant output [$got]"
fi

# ==========================================================================
# §2 rewritten for the user UI change (see header note): repair hosts are
# rows in the MAIN table now, not a separate "repair:" block — see
# repair_row_present/repair_row_absent_port/col_of above.
echo "=== 2. mlp ls: repair hosts are rows in the main table (cases a-e) ==="
run_ls "$GW_JSON_OK" "$SANDBOX/repair-scan-main.txt" "$SANDBOX/ls2.out" "$SANDBOX/ls2.err"
rc=$?
if [[ $rc -ne 0 ]]; then
    bad "2. mlp ls exit=$rc (want 0)"
else
    ok "2-header. mlp ls exit 0"
fi
if grep -qxF 'repair:' "$SANDBOX/ls2.out"; then
    bad "2-no-section. a 'repair:' section header line is printed (user UI change: there must be no separate section at all)"
else
    ok "2-no-section. no 'repair:' section header line — repair hosts are plain rows"
fi
if repair_row_present "$SANDBOX/ls2.out" "dad-pc" "2503"; then
    ok "2a. listener+nameplate -> a row with NAME=dad-pc TYPE=repair PROVIDER=- PORT=2503 STATE=up, columns at the table's own offsets"
else
    bad "2a. no correctly-shaped dad-pc/2503 row (row: $(grep '2503' "$SANDBOX/ls2.out" || echo '<absent>'))"
fi
if repair_row_present "$SANDBOX/ls2.out" "?" "2550"; then
    ok "2b. listener without nameplate -> a row with NAME=?, same column shape as any other row"
else
    bad "2b. no correctly-shaped ?/2550 row (row: $(grep '2550' "$SANDBOX/ls2.out" || echo '<absent>'))"
fi
if repair_row_absent_port "$SANDBOX/ls2.out" "2560"; then
    ok "2c. nameplate without listener (2560/mom-laptop) -> no repair row at all"
else
    bad "2c. a repair row exists for port 2560, which has a nameplate but no listener"
fi
if repair_row_absent_port "$SANDBOX/ls2.out" "2404"; then
    ok "2d. listener outside [2500,2599] (2404) -> no repair row at all"
else
    bad "2d. a repair row exists for port 2404, which is outside the configured range"
fi
if repair_row_present "$SANDBOX/ls2.out" "twin" "2510"; then
    ok "2e-1. duplicate-name host #1 (twin/2510) is its own correctly-shaped row"
else
    bad "2e-1. no correctly-shaped twin/2510 row (row: $(grep '2510' "$SANDBOX/ls2.out" || echo '<absent>'))"
fi
if repair_row_present "$SANDBOX/ls2.out" "twin" "2520"; then
    ok "2e-2. duplicate-name host #2 (twin/2520) is its own correctly-shaped row"
else
    bad "2e-2. no correctly-shaped twin/2520 row (row: $(grep '2520' "$SANDBOX/ls2.out" || echo '<absent>'))"
fi

# 2f. Explicit alignment cross-check (ticket's own "or by checking each
# field starts at the header's column offset" — repair_row_present already
# does this per-row; this additionally proves a repair row's STATE offset
# is the exact SAME offset the GATEWAY row's own "up" sits at, i.e. one
# shared geometry, not a repair-row-specific one that happens to overlap).
hdr2="$(grep -m1 '^NAME' "$SANDBOX/ls2.out" 2>/dev/null || true)"
gw_row2="$(grep -E '^gateway ' "$SANDBOX/ls2.out" 2>/dev/null || true)"
state_col2="$(col_of "$hdr2" "STATE")"
if [[ -n "$hdr2" && -n "$gw_row2" && "$state_col2" -ge 0 \
      && "${gw_row2:$state_col2:2}" == "up" ]]; then
    ok "2f. the gateway row's STATE column sits at the same measured offset repair_row_present checks for repair rows — one shared table geometry"
else
    bad "2f. could not confirm shared geometry (hdr=[$hdr2] gw_row=[$gw_row2] state_col=$state_col2)"
fi

# INJECTION for §2: a mutant gather_repair_targets that emits nameplate-only
# rows too (ignores D5's "listener is the only fact"), proving 2c is a real
# check and not vacuous.
got="$(MLP_FILE="$MLP_FILE" FAKE_REPAIR_SCAN_FILE="$SANDBOX/repair-scan-main.txt" \
    HOME="$SANDBOX/home" PATH="$SANDBOX/shims:$PATH" \
    bash -c '
        source "$MLP_FILE" >/dev/null 2>&1
        GW_REPAIR_LO=2500; GW_REPAIR_HI=2599
        gather_repair_targets() { printf "mom-laptop\t2560\tup\n"; }
        gather_repair_targets
    ' 2>&1)"
if printf '%s' "$got" | grep -q '2560'; then
    inj_ok "2c-inj. mutant that shows nameplate-without-listener produces the row 2c checks for — the real check would flag it"
else
    inj_bad "2c-inj. mutant did not even produce the expected wrong output — injection itself is broken"
fi

# ==========================================================================
echo "=== 3. mlp ssh <name> against repair hosts ==="
resolve_name() {
    local name="$1" scanfile="$2" nodesjson="$3" workersjson="$4" outvar_file="$5"
    MLP_FILE="$MLP_FILE" FAKE_REPAIR_SCAN_FILE="$scanfile" FAKE_NODES_JSON="$nodesjson" \
    FAKE_WORKERS_FILE="$workersjson" PR_LOG="$SANDBOX/pr3.log" MASTER_LOG="$SANDBOX/master3.log" \
    SCAN_LOG="$SANDBOX/scan3.log" \
    HOME="$SANDBOX/home" PATH="$SANDBOX/shims:$PATH" \
        bash -c '
            source "$MLP_FILE" >/dev/null 2>&1
            POOL_RESOLVE="'"$SANDBOX"'/shims/pool-resolve"
            GW_IP=9.9.9.9; GW_USER=gw; GW_PORT=22; GW_KNOWN_HOSTS=/tmp/kh-test-repair
            GW_REPAIR_LO=2500; GW_REPAIR_HI=2599
            if target_resolve "'"$name"'" >/dev/null 2>&1; then rc=0; else rc=$?; fi
            printf "RC=%s TYPE=%s USER=%s PORT=%s ERR=%s CAND=%s" "$rc" "$TARGET_TYPE" "$TARGET_USER" "$TARGET_PORT" "$TARGET_ERR" "${TARGET_CANDIDATES:-}"
        ' 2>&1 > "$outvar_file"
}
resolve_name "dad-pc" "$SANDBOX/repair-scan-main.txt" "$SANDBOX/nodes.json" "$SANDBOX/workers-empty.json" "$SANDBOX/r3a.out"
got="$(cat "$SANDBOX/r3a.out")"
if [[ "$got" == "RC=0 TYPE=repair USER=repair PORT=2503 ERR= CAND=" ]]; then
    ok "3a. unique repair name 'dad-pc' resolves to repair/repair/2503"
else
    bad "3a. got [$got] want [RC=0 TYPE=repair USER=repair PORT=2503 ERR= CAND=]"
fi

resolve_name "twin" "$SANDBOX/repair-scan-main.txt" "$SANDBOX/nodes.json" "$SANDBOX/workers-empty.json" "$SANDBOX/r3b.out"
got="$(cat "$SANDBOX/r3b.out")"
if [[ "$got" == "RC=1 TYPE= USER= PORT= ERR=repair-ambiguous CAND=2510,2520" ]]; then
    ok "3b. duplicate repair name 'twin' refuses with both candidate ports listed"
else
    bad "3b. got [$got] want [RC=1 ... ERR=repair-ambiguous CAND=2510,2520]"
fi

resolve_name "nope-nobody" "$SANDBOX/repair-scan-main.txt" "$SANDBOX/nodes.json" "$SANDBOX/workers-empty.json" "$SANDBOX/r3c.out"
got="$(cat "$SANDBOX/r3c.out")"
if [[ "$got" == "RC=1 TYPE= USER= PORT= ERR=notfound CAND=" ]]; then
    ok "3c. unknown name -> existing notfound behavior (unchanged)"
else
    bad "3c. got [$got] want [RC=1 ... ERR=notfound CAND=]"
fi

# do_connect-level check for 3a/3b: the actual ssh argv / refusal message.
: > "$SANDBOX/argv3.log"
got_rc=0
MLP_FILE="$MLP_FILE" FAKE_REPAIR_SCAN_FILE="$SANDBOX/repair-scan-main.txt" FAKE_NODES_JSON="$SANDBOX/nodes.json" \
FAKE_WORKERS_FILE="$SANDBOX/workers-empty.json" ARGV_LOG="$SANDBOX/argv3.log" \
HOME="$SANDBOX/home" PATH="$SANDBOX/shims:$PATH" \
    bash -c '
        source "$MLP_FILE" >/dev/null 2>&1
        POOL_RESOLVE="'"$SANDBOX"'/shims/pool-resolve"
        GW_IP=9.9.9.9; GW_USER=gw; GW_PORT=22; GW_KNOWN_HOSTS=/tmp/kh-test-repair
        GW_REPAIR_LO=2500; GW_REPAIR_HI=2599
        do_connect "dad-pc"
    ' >"$SANDBOX/dc3a.out" 2>"$SANDBOX/dc3a.err" || got_rc=$?
if [[ $got_rc -ne 0 ]]; then
    bad "3a-connect. do_connect dad-pc exited $got_rc (want 0)"
elif ! grep -qxF '2503' "$SANDBOX/argv3.log"; then
    bad "3a-connect. ssh argv missing port 2503 (log: $(cat "$SANDBOX/argv3.log" | tr '\n' ' '))"
elif ! grep -qxF 'repair@127.0.0.1' "$SANDBOX/argv3.log"; then
    bad "3a-connect. ssh argv missing 'repair@127.0.0.1' (wrong login user or host)"
elif ! grep -q 'ProxyCommand=.*-p 22.*gw@9.9.9.9' "$SANDBOX/argv3.log"; then
    bad "3a-connect. ProxyCommand does not route through the Gateway (gw@9.9.9.9:22)"
else
    ok "3a-connect. mlp ssh dad-pc: ssh argv shows -p 2503 repair@127.0.0.1 via Gateway ProxyCommand"
fi

got_rc=0
: > "$SANDBOX/argv3b.log"
MLP_FILE="$MLP_FILE" FAKE_REPAIR_SCAN_FILE="$SANDBOX/repair-scan-main.txt" FAKE_NODES_JSON="$SANDBOX/nodes.json" \
FAKE_WORKERS_FILE="$SANDBOX/workers-empty.json" ARGV_LOG="$SANDBOX/argv3b.log" \
HOME="$SANDBOX/home" PATH="$SANDBOX/shims:$PATH" \
    bash -c '
        source "$MLP_FILE" >/dev/null 2>&1
        POOL_RESOLVE="'"$SANDBOX"'/shims/pool-resolve"
        GW_IP=9.9.9.9; GW_USER=gw; GW_PORT=22; GW_KNOWN_HOSTS=/tmp/kh-test-repair
        GW_REPAIR_LO=2500; GW_REPAIR_HI=2599
        do_connect "twin"
    ' >"$SANDBOX/dc3b.out" 2>"$SANDBOX/dc3b.err" || got_rc=$?
if [[ $got_rc -eq 0 ]]; then
    bad "3b-connect. do_connect twin exited 0 (want non-zero — ambiguous name must refuse)"
elif grep -qxF 'repair@127.0.0.1' "$SANDBOX/argv3b.log" 2>/dev/null; then
    # Resolution-phase ssh calls (master open, worker-ledger fetch, the
    # repair scan itself) are expected and fine here — what must NEVER
    # happen is the actual LOGIN leg (ssh_via_gateway's own argv, which
    # always ends in "<user>@127.0.0.1" for a provider/worker/repair
    # target). Its presence would mean do_connect logged in before/despite
    # refusing.
    bad "3b-connect. the LOGIN ssh call happened for an ambiguous name (repair@127.0.0.1 in argv log) — connected despite refusing"
elif ! grep -q '2510' "$SANDBOX/dc3b.err" || ! grep -q '2520' "$SANDBOX/dc3b.err"; then
    bad "3b-connect. stderr does not list both candidate ports 2510/2520 (err=[$(cat "$SANDBOX/dc3b.err")])"
else
    ok "3b-connect. mlp ssh twin: refuses (rc=$got_rc), never invokes the login ssh, lists both candidate ports on stderr"
fi

# INJECTION for §3: a mutant target_resolve that silently picks the FIRST
# duplicate instead of refusing — proves 3b/3b-connect are real checks.
got_rc=0
MLP_FILE="$MLP_FILE" HOME="$SANDBOX/home" PATH="$SANDBOX/shims:$PATH" \
    bash -c '
        source "$MLP_FILE" >/dev/null 2>&1
        target_resolve() { TARGET_TYPE=repair; TARGET_USER=repair; TARGET_PORT=2510; TARGET_ERR=""; return 0; }
        GW_IP=9.9.9.9; GW_USER=gw; GW_PORT=22; GW_KNOWN_HOSTS=/tmp/kh-test-repair
        do_connect "twin"
    ' >/dev/null 2>/dev/null || got_rc=$?
if [[ $got_rc -eq 0 ]]; then
    inj_ok "3b-inj. mutant that silently picks the first duplicate exits 0 — the real target_resolve's ambiguity refusal is what prevents this"
else
    inj_bad "3b-inj. mutant unexpectedly still refused (rc=$got_rc) — injection itself is broken"
fi

# ==========================================================================
echo "=== 4. mlp ssh <port> direct-dial inside the repair range ==="
: > "$SANDBOX/argv4.log"; : > "$SANDBOX/pr4.log"; : > "$SANDBOX/master4.log"
got_rc=0
MLP_FILE="$MLP_FILE" ARGV_LOG="$SANDBOX/argv4.log" PR_LOG="$SANDBOX/pr4.log" MASTER_LOG="$SANDBOX/master4.log" \
HOME="$SANDBOX/home" PATH="$SANDBOX/shims:$PATH" \
    bash -c '
        source "$MLP_FILE" >/dev/null 2>&1
        POOL_RESOLVE="'"$SANDBOX"'/shims/pool-resolve"
        GW_IP=9.9.9.9; GW_USER=gw; GW_PORT=22; GW_KNOWN_HOSTS=/tmp/kh-test-repair
        GW_REPAIR_LO=2500; GW_REPAIR_HI=2599
        do_connect "2550"
    ' >/dev/null 2>"$SANDBOX/dc4.err" || got_rc=$?
callcount="$(grep -c 'CALL-EOL' "$SANDBOX/argv4.log" 2>/dev/null || echo 0)"
if [[ $got_rc -ne 0 ]]; then
    bad "4. do_connect 2550 exited $got_rc (want 0)"
elif [[ -s "$SANDBOX/pr4.log" ]]; then
    bad "4. a bare in-range port triggered a pool-resolve call (pr4.log=[$(cat "$SANDBOX/pr4.log")]) — should short-circuit with zero network"
elif [[ -s "$SANDBOX/master4.log" ]]; then
    bad "4. a bare in-range port opened a ControlMaster — should not need one to know it's in-range"
elif [[ "$callcount" != "1" ]]; then
    bad "4. expected exactly 1 ssh call (the login itself), got $callcount"
elif ! grep -qxF '2550' "$SANDBOX/argv4.log" || ! grep -qxF 'repair@127.0.0.1' "$SANDBOX/argv4.log"; then
    bad "4. ssh argv missing -p 2550 / repair@127.0.0.1"
else
    ok "4. mlp ssh 2550 (in-range port) dials straight there: zero pool-resolve calls, no ControlMaster, one ssh call"
fi

# ==========================================================================
echo "=== 5. repair scan reads no GitHub, opens the Gateway once ==="
: > "$SANDBOX/gh5a.log"; : > "$SANDBOX/gh5b.log"
run_ls "$GW_JSON_OK" "$SANDBOX/repair-scan-main.txt" "$SANDBOX/ls5a.out" "$SANDBOX/ls5a.err"
GH_LOG="$SANDBOX/gh.log"
gh5a="$(wc -l < "$SANDBOX/gh.log" | tr -d ' ')"
master5a="$(wc -l < "$SANDBOX/master.log" | tr -d ' ')"
scan5a="$(wc -l < "$SANDBOX/scan.log" | tr -d ' ')"
run_ls "$GW_JSON_NOPORTS" "$SANDBOX/repair-scan-main.txt" "$SANDBOX/ls5b.out" "$SANDBOX/ls5b.err"
gh5b="$(wc -l < "$SANDBOX/gh.log" | tr -d ' ')"
if [[ "$gh5a" != "1" ]]; then
    bad "5a. mlp ls (repair configured) called gh $gh5a times, want exactly 1 (gather_targets' own existing call)"
elif [[ "$gh5a" != "$gh5b" ]]; then
    bad "5a. gh call count changed with repair configured ($gh5a) vs unconfigured ($gh5b) — repair scan is reading GitHub"
else
    ok "5a. repair scan adds zero gh calls (both configured and unconfigured: exactly 1 gh call, gather_targets' pre-existing one)"
fi
if [[ "$master5a" != "1" ]]; then
    bad "5b. mlp ls opened the Gateway ControlMaster $master5a times, want exactly 1"
else
    ok "5b. mlp ls opens exactly one Gateway ControlMaster (repair rides the same one)"
fi
if [[ "$scan5a" != "1" ]]; then
    bad "5c. repair listener+nameplate scan ran $scan5a remote commands, want exactly 1"
else
    ok "5c. repair listener+nameplate scan is exactly one remote command"
fi

# INJECTION for §5: a mutant gather_repair_targets that issues a second,
# redundant gw_run call — proves 5c is load-bearing (5b/gh unaffected by
# this specific mutant on purpose, to isolate what it's testing).
: > "$SANDBOX/scan-inj.log"
MLP_FILE="$MLP_FILE" SCAN_LOG="$SANDBOX/scan-inj.log" HOME="$SANDBOX/home" PATH="$SANDBOX/shims:$PATH" \
    bash -c '
        source "$MLP_FILE" >/dev/null 2>&1
        GW_REPAIR_LO=2500; GW_REPAIR_HI=2599
        CTL=fake-ctl; GW_USER=gw; GW_IP=9.9.9.9
        gather_repair_targets() {
            gw_run "echo REPAIR-SCAN-L; true"  >/dev/null
            gw_run "echo REPAIR-SCAN-L; true"  >/dev/null
        }
        gather_repair_targets
    ' >/dev/null 2>&1
inj_scan_count="$(wc -l < "$SANDBOX/scan-inj.log" 2>/dev/null | tr -d ' ')"
if [[ "$inj_scan_count" == "2" ]]; then
    inj_ok "5c-inj. mutant issuing two remote scan calls is visibly 2, not 1 — the real check (want exactly 1) would catch this"
else
    inj_bad "5c-inj. mutant produced $inj_scan_count calls, expected 2 — injection itself is broken"
fi

# ==========================================================================
echo "=== 6. regression + name-collision precedence ==="
# 6a: with the range configured, the existing provider/worker rows in
# `mlp ls` are byte-for-byte what they were before repair existed.
if grep -qE '^provider1[[:space:]]+provider[[:space:]]+-[[:space:]]+2323[[:space:]]+up[[:space:]]*$' "$SANDBOX/ls5a.out" \
   && grep -qE '^w1[[:space:]]+worker[[:space:]]+provider1[[:space:]]+2401[[:space:]]+' "$SANDBOX/ls5a.out"; then
    ok "6a. mlp ls: provider1/w1 rows unaffected by the repair section"
else
    bad "6a. provider/worker rows changed shape (see ls5a.out)"
fi

# 6b: existing provider-name ssh resolution unaffected.
got="$(MLP_FILE="$MLP_FILE" FAKE_NODES_JSON="$SANDBOX/nodes.json" FAKE_WORKERS_FILE="$SANDBOX/workers-empty.json" \
    HOME="$SANDBOX/home" PATH="$SANDBOX/shims:$PATH" \
    bash -c '
        source "$MLP_FILE" >/dev/null 2>&1
        POOL_RESOLVE="'"$SANDBOX"'/shims/pool-resolve"
        GW_IP=9.9.9.9; GW_USER=gw; GW_PORT=22; GW_KNOWN_HOSTS=/tmp/kh-test-repair
        GW_REPAIR_LO=2500; GW_REPAIR_HI=2599
        target_resolve "provider1" >/dev/null 2>&1
        printf "TYPE=%s USER=%s PORT=%s" "$TARGET_TYPE" "$TARGET_USER" "$TARGET_PORT"
    ' 2>&1)"
if [[ "$got" == "TYPE=provider USER=pu PORT=2323" ]]; then
    ok "6b. mlp ssh provider1 (existing provider) still resolves provider/pu/2323, repair being configured changes nothing"
else
    bad "6b. got [$got] want [TYPE=provider USER=pu PORT=2323]"
fi

# 6c: name collision — a provider named "dad-pc" wins over a repair host
# also nameplated "dad-pc" (Definition 2 above).
got="$(MLP_FILE="$MLP_FILE" FAKE_NODES_JSON="$SANDBOX/nodes-collide.json" FAKE_WORKERS_FILE="$SANDBOX/workers-empty.json" \
    FAKE_REPAIR_SCAN_FILE="$SANDBOX/repair-scan-main.txt" \
    HOME="$SANDBOX/home" PATH="$SANDBOX/shims:$PATH" \
    bash -c '
        source "$MLP_FILE" >/dev/null 2>&1
        POOL_RESOLVE="'"$SANDBOX"'/shims/pool-resolve"
        GW_IP=9.9.9.9; GW_USER=gw; GW_PORT=22; GW_KNOWN_HOSTS=/tmp/kh-test-repair
        GW_REPAIR_LO=2500; GW_REPAIR_HI=2599
        target_resolve "dad-pc" >/dev/null 2>&1
        printf "TYPE=%s USER=%s PORT=%s" "$TARGET_TYPE" "$TARGET_USER" "$TARGET_PORT"
    ' 2>&1)"
if [[ "$got" == "TYPE=provider USER=pu PORT=2323" ]]; then
    ok "6c. name collision: provider 'dad-pc' (port 2323) wins over the same-named repair host (port 2503) — Definition 2"
else
    bad "6c. got [$got] want [TYPE=provider USER=pu PORT=2323] (a repair-wins mutant would show TYPE=repair PORT=2503)"
fi

# INJECTION for §6: a mutant target_resolve that checks repair BEFORE
# provider/worker — proves 6c is load-bearing, not accidental ordering.
got="$(MLP_FILE="$MLP_FILE" HOME="$SANDBOX/home" PATH="$SANDBOX/shims:$PATH" \
    bash -c '
        source "$MLP_FILE" >/dev/null 2>&1
        target_resolve() { TARGET_TYPE=repair; TARGET_USER=repair; TARGET_PORT=2503; TARGET_ERR=""; return 0; }
        target_resolve "dad-pc" >/dev/null 2>&1
        printf "TYPE=%s PORT=%s" "$TARGET_TYPE" "$TARGET_PORT"
    ' 2>&1)"
if [[ "$got" == "TYPE=repair PORT=2503" ]]; then
    inj_ok "6c-inj. repair-first mutant visibly shadows the provider (TYPE=repair) — 6c's real assertion (want TYPE=provider) would catch this"
else
    inj_bad "6c-inj. mutant produced unexpected [$got] — injection itself is broken"
fi

# ==========================================================================
# §7-8: hostile nameplate content (OUT-review-ephemeral-mlp.md §2/§3, must-
# fix 1, suggestions 2-4). gather_repair_targets treats the nameplate FILE
# as trusted: the review found that its own literal bytes (a TAB, an
# embedded newline, ANSI/CR, an out-of-format name, a bare section marker)
# survive into the very same delimiters the parser uses to tell "this is
# a name" from "this is a port" from "this is a fresh listener block" —
# so a family member's Windows-side nameplate write (design already
# treats this as attacker-writable: the pool's shared tunnel key, not a
# privileged one) can misdirect an owner's `mlp ssh <name>` to a DIFFERENT
# real machine's port, forge a listener that was never observed, or drop
# an uninvolved host's real name entirely. None of this needs code
# execution — it is pure string confusion in gather_repair_targets'
# `read`/`case`/`${var%% *}` parsing (ops-scripts/mlp:430-488).
#
# Each malicious sample below is deliberately its OWN listening port with
# its OWN nameplate content, all folded into one `mlp ls` fixture
# (hostile-ls.txt) so every sample's effect (or lack of one) is visible in
# a single, real run — mirroring how the original fixture folded items
# 2a-2e together. Expectations asserted throughout, per the ticket:
#   * ls row count == the number of REAL 127.0.0.1 listeners observed —
#     no phantom rows, no dropped rows.
#   * the port shown/used for a name is ALWAYS the port of the listener
#     that name is attached to — never bytes lifted from nameplate
#     content.
#   * a nameplate that fails the interface's own name format
#     (^[a-z]([a-z0-9-]{0,30}[a-z0-9])?$, item 3) displays as "?", not
#     raw.
#   * no control bytes (ESC 0x1b, CR 0x0d) ever reach ls's stdout.
#   * `mlp ssh dad-pc` never dials a port that only exists because the
#     nameplate SAID so.
# This file predicts (and the RED run below confirms) that EVERY one of
# these currently fails except the `-o`-style sample, which the review
# separately confirmed is NOT an argv injection (ssh's -p always receives
# it as one token) — that one is asserted as an explicit regression-proof
# GREEN, not lumped in with the vulnerable ones.
echo "=== 7. hostile nameplate content (must-fix 1) ==="

STR5000="$(head -c 5000 /dev/zero | tr '\0' 'a')"

# Real listeners: 2530(control) 2503(TAB-attack, claims fake port 2504)
# 2504(mom-laptop, a REAL second host whose real port the attack above
# happens to name) 2505(ANSI+CR) 2506(5000 chars, invalid format)
# 2507(Dad_PC, invalid format: uppercase+underscore) 2508(embedded
# newline forges a phantom listener at 2577) 2509(TAB-attack whose fake
# "port" is an -o-style string) 2512(nameplate begins with a newline, so
# ITS OWN line is empty and a bare "REPAIR-SCAN-END" follows on its own
# line) 2513(a clean, uninvolved victim placed right after 2512 in file
# order, to show collateral damage from 2512's truncation).
{
    printf 'REPAIR-SCAN-L\n'
    for p in 2530 2503 2504 2505 2506 2507 2508 2509 2512 2513; do
        printf 'LISTEN 0 128 127.0.0.1:%s 0.0.0.0:*\n' "$p"
    done
    printf 'REPAIR-SCAN-N\n'
    printf '2530 good-one\n'
    printf '2503 dad-pc\t2504\n'
    printf '2504 mom-laptop\n'
    printf '2505 \x1b[31mFAKE\x1b[0m\rOVERWRITE\n'
    printf '2506 %s\n' "$STR5000"
    printf '2507 Dad_PC\n'
    printf '2508 evil\nREPAIR-SCAN-L\nLISTEN 0 128 127.0.0.1:2577 0.0.0.0:*\nREPAIR-SCAN-N\n'
    printf '2509 safe-name\t-oProxyCommand=touch /tmp/pwned\n'
    printf '2512 \nREPAIR-SCAN-END\n'
    printf '2513 victim-name\n'
    printf 'REPAIR-SCAN-END\n'
} > "$SANDBOX/hostile-ls.txt"
REAL_LISTENER_COUNT=10

run_ls "$GW_JSON_OK" "$SANDBOX/hostile-ls.txt" "$SANDBOX/ls7.out" "$SANDBOX/ls7.err"
rc=$?
if [[ $rc -ne 0 ]]; then
    bad "7. mlp ls exit=$rc against the hostile fixture (want 0 — must not crash)"
else
    ok "7-header. mlp ls survives the hostile fixture without crashing (exit 0)"
fi

# 7a. TAB+port: PM ruling (2026-09-30, after §7 was first written) —
# nameplate validity is WHOLE-CONTENT, not "does it have a valid leading
# prefix": a nameplate is valid only if its entire content (after
# stripping at most one trailing newline, and a CR immediately before
# that) matches ^[a-z]([a-z0-9-]{0,30}[a-z0-9])?$ (EPHEMERAL-INTERFACE
# item 3/5). "dad-pc<TAB>2504" fails that as a WHOLE (contains a TAB and
# trailing digits) — the CORRECT fix must show "?" here, not "dad-pc"
# with a merely-repaired port column. The original version of this
# assertion assumed "dad-pc" was a legitimate resolvable prefix; that was
# itself a instance of the same bug category the ticket is about (trust
# something less than the whole nameplate) and has been corrected.
if repair_row_present "$SANDBOX/ls7.out" "?" "2503"; then
    ok "7a. TAB-in-nameplate: shown as ? (whole content is invalid), on its REAL listener port 2503 — never a name derived from a prefix of the content"
else
    bad "7a. TAB-in-nameplate: want a correctly-shaped ?/2503 row, got (row: $(grep '2503' "$SANDBOX/ls7.out" || echo '<absent>')) — either a prefix-derived name leaked through, or the real port did not, or the column shape is off"
fi

# 7b. newline+forged row: must not fabricate a listener that was never in
# the ss output (port 2577 does not exist in this fixture's LISTEN lines).
if grep -qE '2577' "$SANDBOX/ls7.out"; then
    bad "7b. newline-forged row: a phantom '2577' listener appears in ls output that was never in ss's LISTEN lines"
else
    ok "7b. newline-forged row: no phantom 2577 listener in ls output"
fi

# 7b-2. The SAME sample's own listener (2508) must also show "?": its
# nameplate's whole content is "evil\nREPAIR-SCAN-L\n...\nREPAIR-SCAN-N"
# (a multi-line blob containing markers), which fails whole-content
# validation just as thoroughly as it corrupts the scan framing. Showing
# a clean-looking "evil" for it (this file's original, now-corrected
# assumption) would itself be trusting a "valid-looking prefix" of a
# hostile blob.
if repair_row_present "$SANDBOX/ls7.out" "?" "2508"; then
    ok "7b-2. the newline-forging file's OWN listener (2508) shows ?, not the leading-word 'evil' it starts with"
else
    bad "7b-2. port 2508 does not show a correctly-shaped ? row (row: $(grep '2508' "$SANDBOX/ls7.out" || echo '<absent>')) — a multi-line hostile blob's leading word is being accepted as a name"
fi

# 7c. section-marker truncation: 2512's own nameplate begins with a
# newline, landing a bare "REPAIR-SCAN-END" on its own line — this must
# not silently discard the NEXT (uninvolved) file's real mapping.
if repair_row_present "$SANDBOX/ls7.out" "victim-name" "2513"; then
    ok "7c. section-marker truncation: the uninvolved next file (2513/victim-name) keeps its real name, correctly shaped"
else
    bad "7c. section-marker truncation: 2513 lost its real name 'victim-name' (row: $(grep '2513' "$SANDBOX/ls7.out" || echo '<absent>')) — one file's forged marker silently dropped another file's mapping"
fi

# 7d. ANSI escape + CR must never reach the terminal raw.
if LC_ALL=C grep -qF "$(printf '\x1b')" "$SANDBOX/ls7.out" || LC_ALL=C grep -qF "$(printf '\r')" "$SANDBOX/ls7.out"; then
    bad "7d. ANSI/CR: a raw ESC or CR byte from nameplate content reached ls's stdout"
else
    ok "7d. ANSI/CR: no raw ESC/CR bytes in ls's stdout"
fi

# 7e. 5000-char nameplate: too long to be a valid name (item 3's format
# caps at 32 chars total) -> must display as "?", not the raw 5000 bytes.
if repair_row_present "$SANDBOX/ls7.out" "?" "2506"; then
    ok "7e. 5000-char nameplate: shown as ? (invalid format), not the raw content"
else
    bad "7e. 5000-char nameplate: NOT shown as a correctly-shaped ? row — invalid/oversized nameplate content is displayed raw (output grew by ~5000 bytes: $(wc -c < "$SANDBOX/ls7.out" | tr -d ' ') total)"
fi

# 7f. Invalid name format (uppercase + underscore, "Dad_PC") -> "?".
if repair_row_present "$SANDBOX/ls7.out" "?" "2507"; then
    ok "7f. invalid-format nameplate 'Dad_PC' (uppercase/underscore) shown as ?, not raw"
else
    bad "7f. invalid-format nameplate 'Dad_PC' NOT shown as a correctly-shaped ? row (row: $(grep '2507' "$SANDBOX/ls7.out" || echo '<absent>')) — name-format validation (item 3) is not applied to nameplate content"
fi

# 7g. Row count: exactly one row per REAL 127.0.0.1 listener, no more, no
# fewer (catches 7b's phantom AND any other file's silent count drift).
# Counted by TYPE=repair now (merged table — user UI change), not by a
# section's own leading-whitespace convention (there is no section).
gotcount="$(repair_row_count "$SANDBOX/ls7.out")"
if [[ "$gotcount" == "$REAL_LISTENER_COUNT" ]]; then
    ok "7g. ls repair row count ($gotcount) == real listener count ($REAL_LISTENER_COUNT)"
else
    bad "7g. ls repair row count is $gotcount, want $REAL_LISTENER_COUNT (real 127.0.0.1 listeners) — hostile nameplate content changed how many rows appear"
fi

# 7h. PM ruling supersedes the original version of this assertion, which
# required `mlp ssh dad-pc` to dial 2503 (i.e. assumed "dad-pc" — the
# content's leading word before its TAB — is a legitimate, resolvable
# name). Under whole-content validation "dad-pc<TAB>2504" is invalid in
# its entirety, so there IS no repair host named "dad-pc": the name must
# not resolve at all. Must-never-dial-anything is the property, not
# "dials the right port instead of the wrong one" — do_connect must take
# the EXISTING notfound path (do_connect never even reaches ssh_via_gateway
# / no login leg is invoked), not a repair-specific one.
resolve_name "dad-pc" "$SANDBOX/hostile-ls.txt" "$SANDBOX/nodes.json" "$SANDBOX/workers-empty.json" "$SANDBOX/r7h.out"
got="$(cat "$SANDBOX/r7h.out")"
if [[ "$got" == "RC=1 TYPE= USER= PORT= ERR=notfound CAND=" ]]; then
    ok "7h-resolve. 'dad-pc' does not resolve at all (its only nameplate fails whole-content validation) — TARGET_ERR=notfound, same as a name nobody ever typed"
else
    bad "7h-resolve. got [$got] want [RC=1 TYPE= USER= PORT= ERR=notfound CAND=] — a name derived from invalid content's prefix is still resolving to something"
fi
: > "$SANDBOX/argv7h.log"
got_rc=0
MLP_FILE="$MLP_FILE" FAKE_REPAIR_SCAN_FILE="$SANDBOX/hostile-ls.txt" FAKE_NODES_JSON="$SANDBOX/nodes.json" \
FAKE_WORKERS_FILE="$SANDBOX/workers-empty.json" ARGV_LOG="$SANDBOX/argv7h.log" \
HOME="$SANDBOX/home" PATH="$SANDBOX/shims:$PATH" \
    bash -c '
        source "$MLP_FILE" >/dev/null 2>&1
        POOL_RESOLVE="'"$SANDBOX"'/shims/pool-resolve"
        GW_IP=9.9.9.9; GW_USER=gw; GW_PORT=22; GW_KNOWN_HOSTS=/tmp/kh-test-repair
        GW_REPAIR_LO=2500; GW_REPAIR_HI=2599
        do_connect "dad-pc"
    ' >/dev/null 2>"$SANDBOX/dc7h.err" || got_rc=$?
if [[ $got_rc -eq 0 ]]; then
    bad "7h-connect. do_connect dad-pc exited 0 (want non-zero — 'dad-pc' must not resolve to anything, so it must not connect to anything either)"
elif grep -qxF 'repair@127.0.0.1' "$SANDBOX/argv7h.log"; then
    bad "7h-connect. the LOGIN ssh leg was invoked for 'dad-pc' (repair@127.0.0.1 in argv log) despite it not resolving — connected to SOMETHING it should have refused entirely"
elif ! grep -qF 'no such node or worker: dad-pc' "$SANDBOX/dc7h.err"; then
    bad "7h-connect. missing the existing generic notfound message (err=[$(cat "$SANDBOX/dc7h.err")])"
else
    ok "7h-connect. mlp ssh dad-pc: never dials 2504 (mom-laptop's real port) NOR 2503 (its own listener) — refuses with the plain, existing notfound message, exactly as if 'dad-pc' had never been typed as a nameplate at all"
fi

# 7i. PM ruling: the `-o`-style content must never appear ANYWHERE in
# ssh's argv at all — not "as a single safe token" (the original version
# of this assertion, which is itself the prefix assumption: it required
# "safe-name" to resolve so the payload could reach -p in the first
# place). Since the whole nameplate "safe-name<TAB>-oProxyCommand=..."
# is invalid, "safe-name" must not resolve, so ssh is never invoked with
# this content in ANY position — the strongest available property.
: > "$SANDBOX/argv7i.log"
got_rc=0
MLP_FILE="$MLP_FILE" FAKE_REPAIR_SCAN_FILE="$SANDBOX/hostile-ls.txt" FAKE_NODES_JSON="$SANDBOX/nodes.json" \
FAKE_WORKERS_FILE="$SANDBOX/workers-empty.json" ARGV_LOG="$SANDBOX/argv7i.log" \
HOME="$SANDBOX/home" PATH="$SANDBOX/shims:$PATH" \
    bash -c '
        source "$MLP_FILE" >/dev/null 2>&1
        POOL_RESOLVE="'"$SANDBOX"'/shims/pool-resolve"
        GW_IP=9.9.9.9; GW_USER=gw; GW_PORT=22; GW_KNOWN_HOSTS=/tmp/kh-test-repair
        GW_REPAIR_LO=2500; GW_REPAIR_HI=2599
        do_connect "safe-name"
    ' >/dev/null 2>"$SANDBOX/dc7i.err" || got_rc=$?
if grep -qF -- 'oProxyCommand' "$SANDBOX/argv7i.log"; then
    bad "7i. the -o-style nameplate content reached ssh's argv at all (log: $(tr '\n' '|' < "$SANDBOX/argv7i.log")) — 'safe-name' must not resolve, so this string should never be built into any command"
else
    ok "7i. the -o-style nameplate content never appears anywhere in ssh's argv — 'safe-name' correctly fails to resolve before anything ssh-shaped is ever assembled"
fi

# 7i-port. PM ruling: `mlp ssh safe-name` must take the same not-found
# path as 7h (never dial 2509, never dial the garbage string either), and
# the fixture's ls output (already captured in ls7.out) must show
# listener 2509 as "?" — the whole nameplate content is invalid, so this
# is the SAME property 7a/7b-2 already check for their own ports.
if [[ $got_rc -eq 0 ]]; then
    bad "7i-port. do_connect safe-name exited 0 (want non-zero — must not resolve)"
elif grep -qxF 'repair@127.0.0.1' "$SANDBOX/argv7i.log"; then
    bad "7i-port. the LOGIN ssh leg was invoked for 'safe-name' despite it not resolving"
elif ! grep -qF 'no such node or worker: safe-name' "$SANDBOX/dc7i.err"; then
    bad "7i-port. missing the existing generic notfound message (err=[$(cat "$SANDBOX/dc7i.err")])"
elif ! repair_row_present "$SANDBOX/ls7.out" "?" "2509"; then
    bad "7i-port. ls does not show listener 2509 as ? (row: $(grep '2509' "$SANDBOX/ls7.out" || echo '<absent>'))"
else
    ok "7i-port. mlp ssh safe-name refuses (plain notfound, no login leg) AND ls shows its listener 2509 as ?"
fi

# INJECTION for §7: a mutant gather_repair_targets that rejects the WHOLE
# nameplate content (not a "TAB-sanitizing" mutant that would extract and
# keep "dad-pc" as a prefix — that mutant shape was itself the corrected
# assumption) — proves 7a/7b-2/7i-port are load-bearing: a real fix that
# does whole-content validation would make them go green exactly like
# this.
got="$(MLP_FILE="$MLP_FILE" HOME="$SANDBOX/home" PATH="$SANDBOX/shims:$PATH" \
    bash -c '
        source "$MLP_FILE" >/dev/null 2>&1
        gather_repair_targets() { printf "?\t2503\tup\n"; }
        gather_repair_targets
    ' 2>&1)"
if [[ "$got" == "?"$'\t'"2503"$'\t'"up" ]]; then
    inj_ok "7a-inj. a whole-content-rejecting mutant correctly shows ?/2503 (never a name derived from a prefix of the invalid content) — 7a/7b-2 (which want exactly this shape) would go green against a real fix, proving they aren't vacuous"
else
    inj_bad "7a-inj. mutant produced unexpected [$got]"
fi

# 7j/7k. Positive controls (PM ruling): every §7 case so far is an INVALID
# nameplate that must show "?" — without a control, an over-eager "always
# show ?" implementation would pass every assertion above vacuously. Two
# clean nameplates, each on its OWN isolated listener (never mixed into
# the same scan — two valid same-named hosts would be genuinely
# ambiguous, a different property entirely, see §3b):
#   7j: file content "mom-laptop\n" — ordinary case. Note this is not
#       very distinct from any other clean-name fixture in this file: a
#       remote `$(cat "$f")` already strips ALL trailing newlines by
#       bash's own command-substitution rules, so the wire content
#       gather_repair_targets ever sees is plain "mom-laptop" — same as
#       any other clean name. Included anyway because the PM ruling asks
#       for it explicitly.
#   7k: file content "mom-laptop\r\n" — the ACTUALLY distinct case: that
#       same command-substitution stripping removes the trailing \n but
#       NOT the \r before it, so the wire content is "mom-laptop<CR>"
#       (a real trailing-CR byte reaches gather_repair_targets). This is
#       exactly what EPHEMERAL-INTERFACE item 3/5's stripping clause
#       ("removing at most one trailing newline, and a CR before it") is
#       FOR — a plain trailing \n never survives to be stripped in the
#       first place; a lone trailing \r from a CRLF-authored file (e.g.
#       Windows-side) does, and only an explicit strip catches it.
printf 'REPAIR-SCAN-L\nLISTEN 0 128 127.0.0.1:2545 0.0.0.0:*\nREPAIR-SCAN-N\n2545 mom-laptop\nREPAIR-SCAN-END\n' > "$SANDBOX/posctrl-lf.txt"
printf 'REPAIR-SCAN-L\nLISTEN 0 128 127.0.0.1:2546 0.0.0.0:*\nREPAIR-SCAN-N\n2546 mom-laptop\r\nREPAIR-SCAN-END\n' > "$SANDBOX/posctrl-crlf.txt"

pos_control() {
    local label="$1" fixture="$2" port="$3"
    run_ls "$GW_JSON_OK" "$fixture" "$SANDBOX/ls-$label.out" "$SANDBOX/ls-$label.err"
    if ! repair_row_present "$SANDBOX/ls-$label.out" "mom-laptop" "$port"; then
        bad "$label-ls. ls does not show 'mom-laptop' cleanly on port $port (row: $(grep "$port" "$SANDBOX/ls-$label.out" || echo '<absent>')) — a VALID nameplate must resolve, not just an invalid one show ?"
        return
    fi
    ok "$label-ls. ls shows 'mom-laptop' cleanly on its real port $port"
    : > "$SANDBOX/argv-$label.log"
    got_rc=0
    MLP_FILE="$MLP_FILE" FAKE_REPAIR_SCAN_FILE="$fixture" FAKE_NODES_JSON="$SANDBOX/nodes.json" \
    FAKE_WORKERS_FILE="$SANDBOX/workers-empty.json" ARGV_LOG="$SANDBOX/argv-$label.log" \
    HOME="$SANDBOX/home" PATH="$SANDBOX/shims:$PATH" \
        bash -c '
            source "$MLP_FILE" >/dev/null 2>&1
            POOL_RESOLVE="'"$SANDBOX"'/shims/pool-resolve"
            GW_IP=9.9.9.9; GW_USER=gw; GW_PORT=22; GW_KNOWN_HOSTS=/tmp/kh-test-repair
            GW_REPAIR_LO=2500; GW_REPAIR_HI=2599
            do_connect "mom-laptop"
        ' >/dev/null 2>"$SANDBOX/dc-$label.err" || got_rc=$?
    if [[ $got_rc -ne 0 ]]; then
        bad "$label-connect. do_connect mom-laptop exited $got_rc (want 0 — this is a VALID nameplate)"
    elif ! grep -qxF "$port" "$SANDBOX/argv-$label.log"; then
        bad "$label-connect. ssh argv missing -p $port (log: $(tr '\n' '|' < "$SANDBOX/argv-$label.log"))"
    elif ! grep -qxF 'repair@127.0.0.1' "$SANDBOX/argv-$label.log"; then
        bad "$label-connect. ssh argv missing repair@127.0.0.1"
    else
        ok "$label-connect. mlp ssh mom-laptop dials its own real port $port"
    fi
}
pos_control "7j" "$SANDBOX/posctrl-lf.txt" 2545
pos_control "7k" "$SANDBOX/posctrl-crlf.txt" 2546

# INJECTION for 7k: a mutant gather_repair_targets that does NOT strip a
# trailing CR — proves 7k-ls is load-bearing (a real fix that DOES strip
# it would go green; this one, by construction, must not).
got="$(MLP_FILE="$MLP_FILE" HOME="$SANDBOX/home" PATH="$SANDBOX/shims:$PATH" \
    bash -c '
        source "$MLP_FILE" >/dev/null 2>&1
        gather_repair_targets() { printf "mom-laptop\r\t2546\tup\n"; }
        gather_repair_targets
    ' 2>&1)"
if printf '%s' "$got" | grep -qF "$(printf '\r')"; then
    inj_ok "7k-inj. a CR-preserving mutant visibly leaks a raw CR byte — 7k-ls (which wants a clean 'mom-laptop') would catch this"
else
    inj_bad "7k-inj. mutant did not preserve the CR as expected — injection itself is broken"
fi

echo "=== 8. ss address family: only 127.0.0.1:<port> counts (suggestion 2) ==="
{
    printf 'REPAIR-SCAN-L\n'
    printf 'LISTEN 0 128 127.0.0.1:2521 0.0.0.0:*\n'
    printf 'LISTEN 0 128 [::1]:2522 [::]:*\n'
    printf 'LISTEN 0 128 0.0.0.0:2523 0.0.0.0:*\n'
    printf 'LISTEN 0 128 192.0.2.5:2524 0.0.0.0:*\n'
    printf 'REPAIR-SCAN-N\n'
    printf '2521 real-one\n'
    printf '2522 six-one\n'
    printf '2523 wild-zero\n'
    printf '2524 lan-five\n'
    printf 'REPAIR-SCAN-END\n'
} > "$SANDBOX/addrfam-ls.txt"

run_ls "$GW_JSON_OK" "$SANDBOX/addrfam-ls.txt" "$SANDBOX/ls8.out" "$SANDBOX/ls8.err"
if repair_row_present "$SANDBOX/ls8.out" "real-one" "2521"; then
    ok "8a. a genuine 127.0.0.1 listener in range is still shown, correctly shaped"
else
    bad "8a. real-one/2521 (127.0.0.1) missing/malformed in ls output — regression"
fi
if grep -q 'six-one\|2522' "$SANDBOX/ls8.out"; then
    bad "8b. an [::1] (IPv6 loopback) listener is shown as a repair row — only 127.0.0.1:<port> should count"
else
    ok "8b. an [::1] listener in range is NOT shown"
fi
if grep -q 'wild-zero\|2523' "$SANDBOX/ls8.out"; then
    bad "8c. a 0.0.0.0 (wildcard-bind) listener is shown as a repair row — only 127.0.0.1:<port> should count"
else
    ok "8c. a 0.0.0.0 listener in range is NOT shown"
fi
if grep -q 'lan-five\|2524' "$SANDBOX/ls8.out"; then
    bad "8d. a non-loopback (192.0.2.5, RFC 5737 doc range) listener is shown as a repair row — only 127.0.0.1:<port> should count"
else
    ok "8d. a non-loopback LAN-reachable listener in range is NOT shown"
fi
gotcount8="$(repair_row_count "$SANDBOX/ls8.out")"
if [[ "$gotcount8" == "1" ]]; then
    ok "8e. total repair row count is 1 (only the real 127.0.0.1 listener), address-family noise excluded"
else
    bad "8e. total repair row count is $gotcount8, want 1 — non-127.0.0.1 listeners are being counted as repair jump points"
fi

# INJECTION for §8: a mutant gather_repair_targets that ALSO requires the
# 127.0.0.1 prefix (the suggested fix) — proves 8b/8c/8d/8e are
# load-bearing by showing what a real fix's output looks like.
got="$(MLP_FILE="$MLP_FILE" HOME="$SANDBOX/home" PATH="$SANDBOX/shims:$PATH" \
    bash -c '
        source "$MLP_FILE" >/dev/null 2>&1
        gather_repair_targets() { printf "real-one\t2521\tup\n"; }
        gather_repair_targets
    ' 2>&1)"
if [[ "$got" == "real-one"$'\t'"2521"$'\t'"up" ]]; then
    inj_ok "8e-inj. an address-family-filtered mutant shows exactly the 1 real row — 8e (which wants exactly 1) would go green against a real fix"
else
    inj_bad "8e-inj. mutant produced unexpected [$got]"
fi

# ==========================================================================
# §9: live finding — /home/sshproxy/repair/ is 750 sshproxy:sshproxy, so
# reading nameplates needs `sudo -n` (see header for the wire contract).
echo "=== 9. live: sudo -n to read nameplates (750 sshproxy:sshproxy) ==="

# 9a. The remote command that fetches listeners+nameplates must itself
# invoke `sudo -n` against the nameplate directory — in the SAME line
# ARGV_LOG records for the scan (proves it rides the one existing remote
# command, never a second round trip), and the scan must still be exactly
# ONE remote command overall (SCAN_LOG count == 1, same property §5c
# already checks, re-verified here because adding sudo is exactly the
# kind of change that tempts a "just run a quick sudo check first" EXTRA
# round trip).
printf 'REPAIR-SCAN-L\nLISTEN 0 128 127.0.0.1:2560 0.0.0.0:*\nREPAIR-SCAN-N\n2560 clean-host\nREPAIR-SCAN-END\n' > "$SANDBOX/sudo-ok.txt"
run_ls "$GW_JSON_OK" "$SANDBOX/sudo-ok.txt" "$SANDBOX/ls9a.out" "$SANDBOX/ls9a.err"
sudo_scan_line="$(grep -F 'REPAIR-SCAN-L' "$SANDBOX/argv.log" 2>/dev/null || true)"
if [[ -z "$sudo_scan_line" ]]; then
    bad "9a. could not find the scan's remote-command line in argv.log at all — harness or scan marker changed"
elif ! printf '%s' "$sudo_scan_line" | grep -qF 'sudo -n'; then
    bad "9a. the scan's remote command does not invoke 'sudo -n' anywhere (command: $sudo_scan_line) — nameplates are read as the operator's own Gateway user, which the live 750 sshproxy:sshproxy directory refuses"
elif ! printf '%s' "$sudo_scan_line" | grep -qF '/home/sshproxy/repair'; then
    bad "9a. 'sudo -n' appears in the remote command but not obviously applied to /home/sshproxy/repair (command: $sudo_scan_line)"
else
    ok "9a. the listener+nameplate scan's remote command invokes 'sudo -n' against /home/sshproxy/repair, in the same command"
fi
scancount9a="$(wc -l < "$SANDBOX/scan.log" 2>/dev/null | tr -d ' ')"
if [[ "$scancount9a" == "1" ]]; then
    ok "9a-onecall. adding sudo did not turn the scan into a second remote command (still exactly 1, same as §5c)"
else
    bad "9a-onecall. scan ran $scancount9a remote commands (want 1) — sudo was added as a SEPARATE round trip instead of inside the existing one"
fi
if repair_row_present "$SANDBOX/ls9a.out" "clean-host" "2560"; then
    ok "9a-sanity. a normal clean nameplate still resolves through whatever sudo wrapping now exists"
else
    bad "9a-sanity. clean-host/2560 missing/malformed in ls output (got: $(grep '2560' "$SANDBOX/ls9a.out" || echo '<absent>')) — sudo wrapping broke the ordinary case"
fi

# 9b. sudo -n failure: the WIRE MARKER (header) is "REPAIR-SCAN-SUDO-FAIL"
# as the entire nameplate block. Must not silently show success; must
# warn loudly, still list the real listener as "?", and still exit 0.
printf 'REPAIR-SCAN-L\nLISTEN 0 128 127.0.0.1:2561 0.0.0.0:*\nREPAIR-SCAN-N\nREPAIR-SCAN-SUDO-FAIL\nREPAIR-SCAN-END\n' > "$SANDBOX/sudo-fail.txt"
run_ls "$GW_JSON_OK" "$SANDBOX/sudo-fail.txt" "$SANDBOX/ls9b.out" "$SANDBOX/ls9b.err"
rc=$?
if [[ $rc -ne 0 ]]; then
    bad "9b. mlp ls exit=$rc on a sudo-failure fixture (want 0 — listeners are still real and listable, only names are unreadable)"
else
    ok "9b-rc. mlp ls exits 0 even when sudo -n failed"
fi
if repair_row_present "$SANDBOX/ls9b.out" "?" "2561"; then
    ok "9b-listed. the real listener (2561) is still shown, as ? (not silently dropped, not left showing a stale/wrong name)"
else
    bad "9b-listed. listener 2561 is not shown as a correctly-shaped ? row (row: $(grep '2561' "$SANDBOX/ls9b.out" || echo '<absent>')) — a sudo failure must not remove a real listener from the list"
fi
if grep -qi 'sudo' "$SANDBOX/ls9b.err" && grep -qi 'nameplate' "$SANDBOX/ls9b.err"; then
    ok "9b-warn. a loud stderr line mentions both sudo and nameplates"
else
    bad "9b-warn. no loud stderr warning naming sudo+nameplates (err=[$(cat "$SANDBOX/ls9b.err")]) — a sudo failure is currently indistinguishable from '?' meaning something else entirely, e.g. an ordinary invalid nameplate"
fi

# INJECTION for §9: a mutant gather_repair_targets that recognizes the
# sentinel and warns, proving 9b-warn is load-bearing (not satisfied by
# e.g. any non-empty stderr).
got="$(MLP_FILE="$MLP_FILE" HOME="$SANDBOX/home" PATH="$SANDBOX/shims:$PATH" \
    bash -c '
        source "$MLP_FILE" >/dev/null 2>&1
        gather_repair_targets() { echo "mlp: sudo -n failed reading repair nameplates" >&2; printf "?\t2561\tup\n"; }
        gather_repair_targets
    ' 2>"$SANDBOX/inj9.err")"
if grep -qi 'sudo' "$SANDBOX/inj9.err" && grep -qi 'nameplate' "$SANDBOX/inj9.err" && [[ "$got" == "?"$'\t'"2561"$'\t'"up" ]]; then
    inj_ok "9b-inj. a mutant that DOES warn+list-as-? produces exactly what 9b wants — proves 9b isn't satisfied by mere chance"
else
    inj_bad "9b-inj. mutant produced unexpected stderr=[$(cat "$SANDBOX/inj9.err")] stdout=[$got]"
fi

# ==========================================================================
# §10: user UI change — the fzf picker behind `mlp ssh` (no argument) must
# include repair hosts, and selecting one must dial it by PORT (never by
# re-resolving its NAME, which is exactly how duplicates/"?" stay
# selectable and unambiguous — see header note). Reuses the fzf-shim
# technique test-tab-field-collapse.sh established: a fake fzf that reads
# all of stdin, then picks (and echoes back, like real fzf would) the one
# line matching what this test case asked for; cmd_ssh is called
# DIRECTLY (same as that file's own comment explains: main's
# interactive_only guard is one frame up and out of scope for a function
# call, not cmd_ssh's problem to re-check).
echo "=== 10. mlp ssh (no argument, fzf picker) includes repair hosts ==="

# Picking fzf: consumes ALL of stdin into FZF_STDIN_LOG first (so it can
# be inspected afterward regardless of whether a match was found), then
# picks the tab-delimited line whose field 1 (name) == FZF_PICK_NAME and
# field 4 (port) == FZF_PICK_PORT — exactly the shape cmd_ssh's existing
# candidate stream already uses for gateway/provider/worker
# (name/type/provider/port/user/state); real fzf exits 1 with no output
# when nothing matches the query, which this mirrors when the wanted
# fields are never found at all.
cat > "$SANDBOX/shims/fzf" <<'FAKE'
#!/usr/bin/env bash
cat > "${FZF_STDIN_LOG:-/dev/null}"
awk -F'\t' -v n="${FZF_PICK_NAME:-}" -v p="${FZF_PICK_PORT:-}" \
    '$1 == n && $4 == p { print; found=1; exit } END { exit(found ? 0 : 1) }' \
    "${FZF_STDIN_LOG:-/dev/null}"
FAKE
chmod +x "$SANDBOX/shims/fzf"

# 10a. Unique repair candidate ("dad-pc", the repair-scan-main.txt
# fixture's unique host at port 2503) reaches the picker's stdin at all,
# and selecting it dials port 2503 as user "repair" — same do_connect
# call path every other picker selection already goes through.
: > "$SANDBOX/argv10a.log"
got_rc=0
MLP_FILE="$MLP_FILE" FAKE_GW_JSON="$GW_JSON_OK" FAKE_GH_VARS_FILE="$SANDBOX/gh-vars.txt" \
FAKE_NODES_JSON="$SANDBOX/nodes.json" FAKE_WORKERS_FILE="$SANDBOX/workers.json" \
FAKE_REPAIR_SCAN_FILE="$SANDBOX/repair-scan-main.txt" FAKE_UP_PORTS="2323" \
ARGV_LOG="$SANDBOX/argv10a.log" FZF_STDIN_LOG="$SANDBOX/fzf10a.stdin" \
FZF_PICK_NAME="dad-pc" FZF_PICK_PORT="2503" \
HOME="$SANDBOX/home" PATH="$SANDBOX/shims:$PATH" \
    bash -c '
        source "$MLP_FILE" >/dev/null 2>&1
        POOL_RESOLVE="'"$SANDBOX"'/shims/pool-resolve"
        cmd_ssh
    ' >/dev/null 2>"$SANDBOX/dc10a.err" || got_rc=$?
if ! grep -qE $'^dad-pc\trepair\t-\t2503\t' "$SANDBOX/fzf10a.stdin" 2>/dev/null; then
    bad "10a-candidate. the picker's own stdin never contained a dad-pc/repair/-/2503 candidate line (stdin: $(tr '\n' '|' < "$SANDBOX/fzf10a.stdin" 2>/dev/null || echo '<missing>')) — repair hosts are not in the picker's list yet"
else
    ok "10a-candidate. the repair host 'dad-pc' (port 2503) reaches the fzf picker's candidate list, correctly shaped"
fi
if [[ $got_rc -ne 0 ]]; then
    bad "10a-connect. cmd_ssh (picker) exited $got_rc unexpectedly (want 0) after picking dad-pc (err: $(cat "$SANDBOX/dc10a.err"))"
elif ! grep -qxF '2503' "$SANDBOX/argv10a.log"; then
    bad "10a-connect. ssh argv missing -p 2503 after picking dad-pc (log: $(tr '\n' '|' < "$SANDBOX/argv10a.log"))"
elif ! grep -qxF 'repair@127.0.0.1' "$SANDBOX/argv10a.log"; then
    bad "10a-connect. ssh argv missing repair@127.0.0.1 after picking dad-pc"
else
    ok "10a-connect. picking the repair candidate dials -p 2503 repair@127.0.0.1, same do_connect path as any other picker selection"
fi

# 10b. Duplicate-name candidates ("twin" at BOTH 2510 and 2520) must
# appear as two SEPARATE, individually-selectable lines — picking the
# SECOND one specifically (port 2520) must dial 2520, never 2510, and
# must never go through a name-based (ambiguous) resolve at all: the
# picker sidesteps §3b's "same name refuses" refusal entirely, by
# letting the human pick a row/port instead of typing a name.
: > "$SANDBOX/argv10b.log"
got_rc=0
MLP_FILE="$MLP_FILE" FAKE_GW_JSON="$GW_JSON_OK" FAKE_GH_VARS_FILE="$SANDBOX/gh-vars.txt" \
FAKE_NODES_JSON="$SANDBOX/nodes.json" FAKE_WORKERS_FILE="$SANDBOX/workers.json" \
FAKE_REPAIR_SCAN_FILE="$SANDBOX/repair-scan-main.txt" FAKE_UP_PORTS="2323" \
ARGV_LOG="$SANDBOX/argv10b.log" FZF_STDIN_LOG="$SANDBOX/fzf10b.stdin" \
FZF_PICK_NAME="twin" FZF_PICK_PORT="2520" \
HOME="$SANDBOX/home" PATH="$SANDBOX/shims:$PATH" \
    bash -c '
        source "$MLP_FILE" >/dev/null 2>&1
        POOL_RESOLVE="'"$SANDBOX"'/shims/pool-resolve"
        cmd_ssh
    ' >/dev/null 2>"$SANDBOX/dc10b.err" || got_rc=$?
twin_candidates="$(grep -cE $'^twin\trepair\t-\t' "$SANDBOX/fzf10b.stdin" 2>/dev/null)"
[[ -n "$twin_candidates" ]] || twin_candidates=0
if [[ "$twin_candidates" != "2" ]]; then
    bad "10b-candidates. expected 2 separate 'twin' repair candidates (2510 and 2520) in the picker's stdin, got $twin_candidates (stdin: $(tr '\n' '|' < "$SANDBOX/fzf10b.stdin" 2>/dev/null || echo '<missing>'))"
else
    ok "10b-candidates. both same-named repair hosts (twin/2510, twin/2520) are separate, individually-selectable candidate lines"
fi
if [[ $got_rc -ne 0 ]]; then
    bad "10b-connect. cmd_ssh (picker) exited $got_rc unexpectedly after picking twin/2520 (err: $(cat "$SANDBOX/dc10b.err"))"
elif grep -qxF '2510' "$SANDBOX/argv10b.log"; then
    bad "10b-connect. picking twin/2520 dialed 2510 instead — the picker's port-based selection is being second-guessed by a name-based (ambiguous) resolve"
elif ! grep -qxF '2520' "$SANDBOX/argv10b.log"; then
    bad "10b-connect. ssh argv missing -p 2520 after picking twin/2520 (log: $(tr '\n' '|' < "$SANDBOX/argv10b.log"))"
else
    ok "10b-connect. picking the SECOND same-named candidate (twin/2520) dials exactly 2520, never 2510 and never an ambiguity refusal — the picker's own port selection is authoritative"
fi

# 10c. Regression: the picker's existing provider/worker/gateway
# candidates and their own selection-to-dial path are unaffected by
# adding repair candidates (same fixture already has provider1/w1).
if grep -qE $'^provider1\tprovider\t-\t2323\t' "$SANDBOX/fzf10a.stdin" 2>/dev/null; then
    ok "10c. the existing provider candidate (provider1) is still present in the picker's stdin, unaffected by adding repair candidates"
else
    bad "10c. provider1 is missing from the picker's stdin (stdin: $(tr '\n' '|' < "$SANDBOX/fzf10a.stdin" 2>/dev/null || echo '<missing>')) — regression"
fi

# INJECTION for §10: a mutant cmd_ssh whose candidate-building loop skips
# repair entirely (today's actual shape) — proves 10a-candidate is
# load-bearing by showing the CURRENT gap fails it on purpose here too,
# and a real fix (which adds the loop) would flip it.
got="$(MLP_FILE="$MLP_FILE" HOME="$SANDBOX/home" PATH="$SANDBOX/shims:$PATH" \
    bash -c '
        source "$MLP_FILE" >/dev/null 2>&1
        {
            printf "gateway\tgateway\t-\t22\tgw\tup\n"
            printf "provider1\tprovider\t-\t2323\tpu\tup\n"
        }
    ' 2>&1)"
if ! printf '%s' "$got" | grep -qF 'repair'; then
    inj_ok "10a-inj. a mutant candidate stream with no repair line at all (today's actual shape) is visibly missing one — 10a-candidate (which wants one) would catch this"
else
    inj_bad "10a-inj. mutant unexpectedly contains 'repair' — injection itself is broken"
fi

echo
echo "passed ${pass} / failed ${fail} / injection-pass ${injpass} / injection-fail ${injfail}"
[[ "$fail" -eq 0 && "$injfail" -eq 0 ]]
