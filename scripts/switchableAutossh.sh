#!/usr/bin/env bash

REVERSE_CONFIG=$1 # remote_host:remote_port:local_host:local_port
USER=$2
HOST=$3

export AUTOSSH_PIDFILE=$(pwd)/autossh.pid

# initialize connection
CURRENT_IP_FOR_TARGETHOST=$(dig +short $HOST @1.1.1.1)
autossh -M0 -NfR ${REVERSE_CONFIG} -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null ${USER}@${CURRENT_IP_FOR_TARGETHOST}

# monitor and reconnect if IP has changed
PREV_IP_FOR_TARGETHOST=$CURRENT_IP_FOR_TARGETHOST
while true; do
    CURRENT_IP_FOR_TARGETHOST=$(dig +short $HOST @1.1.1.1)

    # Reconnect if IP has changed
    if [ "$PREV_IP_FOR_TARGETHOST" != "$CURRENT_IP_FOR_TARGETHOST" ]; then
        echo "IP for $HOST has changed from $PREV_IP_FOR_TARGETHOST to $CURRENT_IP_FOR_TARGETHOST, Reconnecting..."

        # Kill old autossh
        kill -9 $(cat $AUTOSSH_PIDFILE) $(pgrep -P $(cat $AUTOSSH_PIDFILE))

        # Restart autossh
        autossh -M0 -NfR ${REVERSE_CONFIG} -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null ${USER}@${CURRENT_IP_FOR_TARGETHOST}

        PREV_IP_FOR_TARGETHOST=$CURRENT_IP_FOR_TARGETHOST
        PREV_AUTOSSH_CMD=$CURRENT_AUTOSSH_CMD
    fi

    sleep 30 # wait dns to propagate
done
