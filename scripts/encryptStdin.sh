#!/usr/bin/env bash

PASSWORD=$1

openssl enc -aes-256-cbc -pbkdf2 -iter 10000 -a -salt -pass pass:"$PASSWORD"