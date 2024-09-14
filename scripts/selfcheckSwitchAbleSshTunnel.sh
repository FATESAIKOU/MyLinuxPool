#!/usr/bin/env bash

# Usage: nohup bash -c "cd /home/fatesaikou/testSH && ./selfCheckSwitchableSshTunnel.sh localhost 2223 localhost 2222 sshproxy fws.csie.io 22" 1>>/home/fatesaikou/testSH/selfCheckSwitchableSshTunnel.log 2>&1 &

REVERSE_REMOTE_HOST=$1
REVERSE_REMOTE_PORT=$2
REVERSE_LOCAL_HOST=$3
REVERSE_LOCAL_PORT=$4
USER=$5
HOST=$6
PORT=$7

SSH_CONTROL_PATH="/tmp/ssh_control_${REVERSE_REMOTE_HOST}:${REVERSE_REMOTE_PORT}:${REVERSE_LOCAL_HOST}:${REVERSE_LOCAL_PORT}_%h_%p_%r"
SSH_CONTROL_REAL_PATH="/tmp/ssh_control_${REVERSE_REMOTE_HOST}:${REVERSE_REMOTE_PORT}:${REVERSE_LOCAL_HOST}:${REVERSE_LOCAL_PORT}_${HOST}_${PORT}_${USER}"

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
            -o ConnectTimeout=5 \
            -p ${PORT} \
            ${USER}@${HOST}
    """

    retStr=$($reversePortTestCmdWithSsh "$reversePortTestCmd" 2>/dev/null)

    #if SSH in retStr return true
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
sshProxyOptions="""
    -o ControlMaster=yes \
    -o ControlPath=${SSH_CONTROL_PATH} \
    -NfR "${REVERSE_REMOTE_HOST}:${REVERSE_REMOTE_PORT}:${REVERSE_LOCAL_HOST}:${REVERSE_LOCAL_PORT}" \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -o ConnectTimeout=5
"""

CURRENT_IP_FOR_TARGETHOST=$(dig +short $HOST @1.1.1.1)
ssh $sshProxyOptions -p ${PORT} ${USER}@${CURRENT_IP_FOR_TARGETHOST}

while true; do
    CURRENT_IP_FOR_TARGETHOST=$(dig +short $HOST @1.1.1.1)

    # Reconnect if IP has changed or ssh connection is broken
    if [ $(test_reverse_sshtunnel) == "false" || "$PREV_IP_FOR_TARGETHOST" != "$CURRENT_IP_FOR_TARGETHOST" ]; then
        ssh -o ControlPath=$SSH_CONTROL_PATH -O exit ${USER}@${CURRENT_IP_FOR_TARGETHOST}
        rm -f "$SSH_CONTROL_REAL_PATH"
        ssh $sshProxyOptions -p ${PORT} ${USER}@${CURRENT_IP_FOR_TARGETHOST}
    fi

    sleep 5
done

