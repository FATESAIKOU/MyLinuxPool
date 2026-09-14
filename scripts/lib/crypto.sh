#!/usr/bin/env bash
# scripts/lib/crypto.sh — symmetric encrypt/decrypt (openssl aes-256-cbc).
#
# Sourced (business-logic scripts): exposes crypto_encrypt <password> and
# crypto_decrypt <password>, both reading their input on stdin and writing
# the result to stdout.
#
# Executed directly (the shared-configs/*/install.sh convention — merged
# here from the former separate encryptStdin.sh/decryptStdin.sh):
#   crypto.sh encrypt <password>   < plaintext  > ciphertext
#   crypto.sh decrypt <password>   < ciphertext > plaintext
# same stdin-in/stdout-out contract either way. The password on argv is
# the one pre-existing, accepted exception to "no secrets as argv" — every
# call site here is local, never remote or logged (see docs/RUNBOOK.md §9).

crypto_encrypt() {
    local password="$1"
    openssl enc -aes-256-cbc -pbkdf2 -iter 10000 -a -salt -pass pass:"$password"
}

crypto_decrypt() {
    local password="$1"
    openssl enc -d -aes-256-cbc -pbkdf2 -iter 10000 -a -pass pass:"$password"
}

# Only dispatch as a standalone command when actually executed, not sourced.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    case "${1:-}" in
        encrypt) shift; crypto_encrypt "${1:-}" ;;
        decrypt) shift; crypto_decrypt "${1:-}" ;;
        *)
            echo "usage: crypto.sh {encrypt|decrypt} <password>   (stdin in, stdout out)" >&2
            exit 2
            ;;
    esac
fi
