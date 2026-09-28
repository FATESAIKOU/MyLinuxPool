#!/usr/bin/env bash
# scripts/lib/refresh-wait.sh — THE single implementation of "dispatch
# refresh-authorized-keys.yml and wait for it to actually finish".
#
# WHY THIS FILE EXISTS (RUNBOOK §7.12, fourth incident): the wait logic was
# implemented twice — scripts/create-worker.sh's
# create_worker_dispatch_refresh_and_wait (fixed after the real run
# 35047640983 failure) and ops-scripts/register-client's trigger_refresh
# (still on the buggy `status != "queued"` poll). Running
# `mlp register client --remove` on 2026-09-16 hit the same failure shape
# again: the poll left the loop the moment the run went in_progress, read
# an empty conclusion, and reported "<unknown>" for a refresh that had
# actually succeeded.
#
# Consumers source this file and call dispatch_refresh_and_wait:
#   - scripts/create-worker.sh (workflows create/delete-worker call it via
#     create_worker_build_run_cmd's caller)
#   - ops-scripts/register-client (mlp register client)
#   - ops-scripts/register-provider.sh (mlp register provider)
#   - ops-scripts/register-repair-host (registers a family repair host)
# A grep for the function DEFINITION across the repo should find exactly
# one place: here.

# refresh_new_nonce — print an unpredictable correlation token (16 hex chars).
#   Primary source is the kernel RNG (/dev/urandom). The timestamp+pid+RANDOM
#   fallback only runs where urandom is unreadable (not our runners, not
#   macOS) — it exists so the function fails attributable rather than empty:
#   an empty nonce would substring-match EVERY title via contains().
#   Why not a bare timestamp (impl-runname hard requirement 4): two callers
#   dispatching in the same second would share it and claim each other's runs.
refresh_new_nonce() {
    local hex=""
    if command -v od >/dev/null 2>&1; then
        hex="$(od -vN8 -An -tx1 /dev/urandom 2>/dev/null | tr -d ' \n' || true)"
    fi
    if [[ "${#hex}" == "16" ]]; then
        printf '%s\n' "${hex}"
        return 0
    fi
    printf '%s-%s-%s%s\n' "$(date +%s)" "$$" "$RANDOM" "$RANDOM"
}

# dispatch_refresh_and_wait [<timeout_seconds>]
#   Dispatches refresh-authorized-keys.yml and waits until OUR run is
#   ACTUALLY completed. Returns 0 iff our run finished with conclusion ==
#   "success"; non-zero on dispatch failure, timeout, a non-success
#   conclusion — or when our run cannot be recognized at all — with timeout,
#   failure, and unrecognized messages distinguishable.
#
#   Attribution (the 2026-09-26 false-green): the dispatch API answers 204
#   without naming the run it created, and this workflow is dispatched from
#   outside the repo every 10–30 minutes, so "the newest run is mine"
#   routinely names somebody else's completed run — whose conclusion (384/384
#   success historically) then reports a green this function did not earn.
#   Instead we mint a nonce (refresh_new_nonce), pass it as the workflow's
#   `nonce` input (surfaced in the run title via `run-name:`), and match
#   displayTitle for it on every poll. A deadline with the nonce never seen
#   returns non-zero saying so — it never falls back to guessing.
#
#   The poll waits for status == "completed" before ever reading the
#   conclusion. Breaking out on `status != "queued"` (the old bug) exits
#   the moment the run goes in_progress, and an in_progress run has no
#   conclusion yet — an empty value then got reported as '<unknown>' and
#   FAILED a refresh that had actually succeeded (real run 35047640983,
#   and again 35074686914 via register-client).
#   GH_REPO comes from the caller's environment (the workflow's env or the
#   operator's shell — docs/LAYOUT.md §3: callers stay thin).
#
#   Residual limits (honest list — the offline test cannot see these):
#   * `run-name:` interpolation reaching displayTitle is unverified from a
#     real dispatch (no dispatching this round); if it does not, every call
#     degrades to safe non-zero, never to somebody else's result.
#   * More runs inside one timeout window than POOL_REFRESH_LIST_LIMIT
#     (default 50) pushes our run out of view — same safe non-zero, at the
#     cost of availability, not correctness.
#   * No local jq needed (matching runs inside gh's own --jq, which is gojq
#     on real gh): one fewer binary to require on fresh provider machines.
dispatch_refresh_and_wait() {
    local timeout_seconds="${1:-300}"
    # Overridable so tests can run a queued→in_progress→completed sequence
    # in seconds instead of the production default's ~10s+; the default
    # keeps production behaviour unchanged.
    local poll_interval="${POOL_REFRESH_POLL_INTERVAL:-5}"
    # Runs inspected per poll. External dispatchers fire every 10–30 min, so
    # a 300 s window can hold dozens of foreign runs behind which ours may
    # sit; --limit 1 (the old shape) mistook the newest foreigner for ours.
    local list_limit="${POOL_REFRESH_LIST_LIMIT:-50}"
    local repo="${GH_REPO:-}"
    local workflow="refresh-authorized-keys.yml"
    local deadline start now
    local nonce="" row run_id="" rest status conclusion seen=""

    if [[ -z "$repo" ]]; then
        log ERROR "GH_REPO is not set — cannot dispatch ${workflow}"
        return 1
    fi

    # The nonce charset is [0-9a-f-] by construction (or the dashed decimal
    # fallback), so interpolating it into the --jq program below cannot break
    # out of its double-quoted string. Never pass a caller-supplied value here.
    nonce="$(refresh_new_nonce)"

    start="$(date +%s)"
    deadline=$((start + timeout_seconds))

    if ! gh workflow run "$workflow" --repo "$repo" -f nonce="${nonce}" >/dev/null 2>&1; then
        log ERROR "could not dispatch ${workflow} (${repo})"
        return 1
    fi

    while :; do
        now="$(date +%s)"
        if (( now >= deadline )); then
            if [[ -n "${seen}" ]]; then
                log ERROR "timed out after ${timeout_seconds}s waiting for our refresh run ${run_id} to finish (still not completed)"
            else
                log ERROR "our own refresh run could not be identified (nonce ${nonce} never appeared in the run list) — 認不出，不猜測"
            fi
            return 1
        fi
        # One call: list a wide window and pick our title locally in gh's
        # --jq (gojq on real gh, jq in the offline fake — contains() and //
        # exist in both). Empty output means "not listed yet" (or pushed out
        # of the window): keep waiting, never treat another run as ours.
        row="$(gh run list --workflow="$workflow" --repo "$repo" --limit "$list_limit" \
            --json databaseId,status,conclusion,displayTitle \
            --jq '[.[] | select(.databaseId != null and ((.displayTitle // "") | contains("'"${nonce}"'")))] | first // empty | "\(.databaseId // 0) \(.status // "") \(.conclusion // "")"' \
            2>/dev/null || true)"
        if [[ -z "${row}" ]]; then
            sleep "$poll_interval"
            continue
        fi
        run_id="${row%% *}"
        rest="${row#* }"
        status="${rest%% *}"
        conclusion="${rest#* }"
        seen="1"
        if [[ "${status}" != "completed" ]]; then
            sleep "$poll_interval"
            continue
        fi
        if [[ "${conclusion}" != "success" ]]; then
            log ERROR "refresh workflow ${run_id} finished with conclusion '${conclusion:-<unknown>}'"
            return 1
        fi
        log INFO "refresh workflow ${run_id} succeeded"
        return 0
    done
}
