#!/usr/bin/env bash

REVERSE_REMOTE_HOST=$1
REVERSE_REMOTE_PORT=$2
REVERSE_LOCAL_HOST=$3
REVERSE_LOCAL_PORT=$4
USER=$5
HOST=$6
PORT=$7

SSH_CONTROL_PATH="/tmp/ssh_control_%h_%p_%r"
SSH_CONTROL_REAL_PATH="/tmp/ssh_control_${HOST}_${PORT}_${USER}"

test_reverse_sshtunnel() {
    reversePortTestCmd="""
        set +m;
        (sleep 1 && killall -9 nc) & disown;
        nc ${REVERSE_REMOTE_HOST} ${REVERSE_REMOTE_PORT};
        echo -n;
        set -m;
    """

    reversePortTestCmdWithSsh="""
        ssh -o StrictHostKeyChecking=no \
            -o UserKnownHostsFile=/dev/null \
            -o ConnectTimeout=1 \
            -p ${PORT} \
            ${USER}@${HOST} \
            ${reversePortTestCmd}
    """

    retStr=$($reversePortTestCmdWithSsh 2>/dev/null)

    # if SSH in retStr return true
    if [[ $retStr == *SSH* ]]; then
        echo "true"
    else
        echo "false"
    fi
}

# cleanup old control socket
if [ -e "$SSH_CONTROL_REAL_PATH" ]; then
    ssh -o ControlPath=$SSH_CONTROL_PATH -O exit ${USER}@${HOST}
    rm -f "$SSH_CONTROL_REAL_PATH"
fi

# initialize connection
sshProxyCmd="""
    ssh -o ControlMaster=yes \
        -o ControlPath=${SSH_CONTROL_PATH} \
        -NfR "${REVERSE_REMOTE_HOST}:${REVERSE_REMOTE_PORT}:${REVERSE_LOCAL_HOST}:${REVERSE_LOCAL_PORT}" \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=1 \
        -p ${PORT} \
        ${USER}@${HOST}
"""

$sshProxyCmd

while true; do
    if [ $(test_reverse_sshtunnel) == "false" ]; then
        ssh -o ControlPath=$SSH_CONTROL_PATH -O exit ${USER}@${HOST}
        rm -f "$SSH_CONTROL_REAL_PATH"
        $sshProxyCmd
    fi

    sleep 1
done
