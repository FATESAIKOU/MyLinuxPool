#!/usr/bin/env bash

PASSWORD=$1

openssl enc -d -aes-256-cbc -pbkdf2 -iter 10000 -a -pass pass:"$PASSWORD"