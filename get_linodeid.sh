#!/usr/bin/env bash
LABEL="${1:-test}"

linode-cli linodes list --json | jq -r ".[] | select(.label == \"$LABEL\") | .id"