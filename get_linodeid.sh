#!/usr/bin/env bash
LABEL="${1:-fws}"

linode-cli linodes list --json | jq -r ".[] | select(.label == \"$LABEL\") | .id"