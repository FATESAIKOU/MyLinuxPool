#!/usr/bin/env bash

REVERSE_REMOTE_HOST=$1
REVERSE_REMOTE_PORT=$2
REVERSE_LOCAL_HOST=$3
REVERSE_LOCAL_PORT=$4
USER=$5
HOST=$6

export SSH_CONTROL_PATH="/tmp/ssh_control_%h_%p_%r"

test_reverse_sshtunnel() {
    retStr=$(ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null ${USER}@${HOST} "set +m; (sleep 1 && killall -9 nc) & disown; nc ${REVERSE_REMOTE_HOST} ${REVERSE_REMOTE_PORT}; echo -n; set -m;" 2>/dev/null)

    # if SSH in retStr return true
    if [[ $retStr == *SSH* ]]; then
        echo "true"
    else
        echo "false"
    fi
}

# initialize connection
ssh -o ControlMaster=yes -o ControlPath=$SSH_CONTROL_PATH -NfR "${REVERSE_REMOTE_HOST}:${REVERSE_REMOTE_PORT}:${REVERSE_LOCAL_HOST}:${REVERSE_LOCAL_PORT}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null ${USER}@${HOST}

while true; do
    if [ $(test_reverse_sshtunnel) == "false" ]; then
        ssh -o ControlPath=$SSH_CONTROL_PATH -O exit ${USER}@${HOST}
        ssh -o ControlMaster=yes -o ControlPath=$SOCKET -NfR "${REVERSE_REMOTE_HOST}:${REVERSE_REMOTE_PORT}:${REVERSE_LOCAL_HOST}:${REVERSE_LOCAL_PORT}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null ${USER}@${HOST}
    fi

    sleep 1
done