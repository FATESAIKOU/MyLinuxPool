#!/usr/bin/env bash

LABEL="${1:-test}"
TYPE="${2:-g6-nanode-1}"
REGION="${3:-ap-northeast}"
IMAGE="${4:-linode/ubuntu24.04}"

ROOT_PASS=$(openssl rand -base64 15 | head -c 20)

linode_cli_ret=$(
    linode-cli linodes create \
        --no-defaults \
        --label test \
        --region ap-northeast \
        --type g6-nanode-1 \
        --image linode/ubuntu24.04 \
        --root_pass $ROOT_PASS\
        --json \
        --metadata.user_data $(. ./set_authorized_keys.sh && cat ./cloud_config.yaml | envsubst | base64)
)

# label
echo $linode_cli_ret | jq -r ".[0] | .label"
# region
echo $linode_cli_ret | jq -r ".[0] | .region"
# type
echo $linode_cli_ret | jq -r ".[0] | .type"
# image
echo $linode_cli_ret | jq -r ".[0] | .image"
# root_pass
echo $ROOT_PASS
# ipv4
echo $linode_cli_ret | jq -r ".[0] | .ipv4"
# ipv6
echo $linode_cli_ret | jq -r ".[0] | .ipv6"