#!/usr/bin/env bash
# scripts/lib/log.sh — the one log() function every scripts/*.sh shares,
# instead of each redefining it. `[YYYY-MM-DDTHH:MM:SSZ] LEVEL msg` on
# stdout for INFO, stderr for everything else (docs/LAYOUT.md §1's
# install.sh convention, reused here for business-logic scripts too).

log() {
    local level="$1"; shift
    local ts
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    if [[ "$level" == "INFO" ]]; then
        printf '[%s] %s %s\n' "$ts" "$level" "$*"
    else
        printf '[%s] %s %s\n' "$ts" "$level" "$*" >&2
    fi
}
