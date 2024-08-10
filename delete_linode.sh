#!/usr/bin/env bash

LABEL="${1:-test}"

linode-cli linodes rm $(./get_linodeid.sh)