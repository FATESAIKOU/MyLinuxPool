#!/usr/bin/env bash

LABEL="${1:-fws}"

linode-cli linodes rm $(./get_linodeid.sh)