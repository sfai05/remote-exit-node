#!/bin/sh
# Print WireGuard keys as vault YAML. Keys go to stdout only — paste them into
# `ansible-vault edit host_vars/<node>/vault.yml`; nothing is written to disk.
# Usage: scripts/wg-keys.sh [--no-server] PEER_NAME...
set -eu

command -v wg >/dev/null 2>&1 || {
    echo "wg not found. macOS: brew install wireguard-tools; Debian: apt install wireguard-tools" >&2
    exit 1
}

server=1
if [ "${1:-}" = "--no-server" ]; then
    server=0
    shift
fi

if [ "$server" -eq 0 ] && [ "$#" -eq 0 ]; then
    echo "Usage: $0 [--no-server] PEER_NAME..." >&2
    exit 1
fi

keypair() {
    priv=$(wg genkey)
    pub=$(printf '%s' "$priv" | wg pubkey)
    printf '%s  private_key: "%s"\n%s  public_key: "%s"\n' "$1" "$priv" "$1" "$pub"
}

if [ "$server" -eq 1 ]; then
    echo "vault_wireguard_server:"
    keypair ""
fi

if [ "$#" -gt 0 ]; then
    echo "vault_wireguard_peers:"
    for name in "$@"; do
        echo "  $name:"
        keypair "  "
    done
fi
