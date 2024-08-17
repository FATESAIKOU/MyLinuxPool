#!/usr/bin/env bash

PROXY_IP=$1
PROXYED_ENTRY_PORT=$2

while true;
do
    echo -n "[$(date)][$PROXY_IP][$PROXYED_ENTRY_PORT] "
    ssh -o LogLevel=ERROR -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null fatesaikou@$PROXY_IP "nc -z -v localhost $PROXYED_ENTRY_PORT"
    sleep 1
done