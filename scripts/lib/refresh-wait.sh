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
# A grep for the function DEFINITION across the repo should find exactly
# one place: here.

# dispatch_refresh_and_wait [<timeout_seconds>]
#   Dispatches refresh-authorized-keys.yml and waits until the run is
#   ACTUALLY completed. Returns 0 iff the run finished with conclusion ==
#   "success"; non-zero on dispatch failure, timeout, or a non-success
#   conclusion — with timeout and failure messages distinguishable.
#
#   The poll waits for status == "completed" before ever reading the
#   conclusion. Breaking out on `status != "queued"` (the old bug) exits
#   the moment the run goes in_progress, and an in_progress run has no
#   conclusion yet — an empty value then got reported as '<unknown>' and
#   FAILED a refresh that had actually succeeded (real run 35047640983,
#   and again 35074686914 via register-client).
#   GH_REPO comes from the caller's environment (the workflow's env or the
#   operator's shell — docs/LAYOUT.md §3: callers stay thin).
dispatch_refresh_and_wait() {
    local timeout_seconds="${1:-300}"
    # Overridable so tests can run a queued→in_progress→completed sequence
    # in seconds instead of the production default's ~10s+; the default
    # keeps production behaviour unchanged.
    local poll_interval="${POOL_REFRESH_POLL_INTERVAL:-5}"
    local repo="${GH_REPO:-}"
    local workflow="refresh-authorized-keys.yml"
    local deadline start now

    if [[ -z "$repo" ]]; then
        log ERROR "GH_REPO is not set — cannot dispatch ${workflow}"
        return 1
    fi

    start="$(date +%s)"
    deadline=$((start + timeout_seconds))

    if ! gh workflow run "$workflow" --repo "$repo" >/dev/null 2>&1; then
        log ERROR "could not dispatch ${workflow} (${repo})"
        return 1
    fi

    local run_id="" row status conclusion
    while :; do
        now="$(date +%s)"
        if (( now >= deadline )); then
            log ERROR "timed out after ${timeout_seconds}s waiting for ${workflow} to finish (still not completed)"
            return 1
        fi
        row="$(gh run list --workflow="$workflow" --repo "$repo" --limit 1 \
            --json databaseId,status --jq '.[0] | "\(.databaseId) \(.status)"' 2>/dev/null || true)"
        if [[ -z "$row" ]]; then
            # The dispatch was accepted but the run is not listed yet.
            sleep "$poll_interval"
            continue
        fi
        run_id="${row%% *}"
        status="${row#* }"
        if [[ "$status" == "completed" ]]; then
            break
        fi
        sleep "$poll_interval"
    done

    # `gh run view --json conclusion` returns an OBJECT in real gh; some
    # gh versions / test fakes return an ARRAY of the same record. Tolerate
    # both shapes so a conclusion read is never a null-by-mismatch.
    conclusion="$(gh run view "$run_id" --repo "$repo" --json conclusion --jq \
        'if type == "array" then .[0].conclusion else .conclusion end' 2>/dev/null || true)"
    if [[ "$conclusion" != "success" ]]; then
        log ERROR "refresh workflow ${run_id} finished with conclusion '${conclusion:-<unknown>}'"
        return 1
    fi
    log INFO "refresh workflow ${run_id} succeeded"
    return 0
}
