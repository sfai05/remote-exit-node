#!/bin/sh
# pre-commit hook: refuse to commit any vault file that is not ansible-vault encrypted.
set -eu

rc=0
for f in "$@"; do
    if [ "$(head -c 14 "$f")" != '$ANSIBLE_VAULT' ]; then
        echo "Refusing to commit unencrypted vault file: $f" >&2
        rc=1
    fi
done
exit "$rc"
