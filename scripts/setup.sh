#!/usr/bin/env bash
# Interactive setup: writes inventory.ini, host_vars/$NODE/vars.yml and an encrypted
# host_vars/$NODE/vault.yml. Values come from the env file / environment; anything unset is asked.
# Usage: scripts/setup.sh [--env FILE]   (default .env; use one file per node, e.g. .env.oracle)
set -euo pipefail

die() { echo "error: $*" >&2; exit 1; }

env_file=.env
while [ $# -gt 0 ]; do
    case $1 in
        --env) [ $# -ge 2 ] || die "--env needs a file"; env_file=$2; shift 2 ;;
        *) die "usage: $0 [--env FILE]" ;;
    esac
done
# Relative to where the script was called from, before switching to the repo root.
case $env_file in /*) ;; *) env_file="$PWD/$env_file" ;; esac

cd "$(dirname "$0")/.."
umask 077

# ask VAR "prompt" [default] [required] — skipped if VAR is already set (empty counts unless required).
ask() {
    local var=$1 prompt=$2 def=${3-} required=${4-} cur isset ans
    eval "cur=\${$var-}; isset=\${$var+x}"
    if [ -n "$isset" ] && { [ -n "$cur" ] || [ -z "$required" ]; }; then return 0; fi
    while :; do
        if [ -n "$def" ]; then
            read -r -p "$prompt [$def]: " ans
            ans=${ans:-$def}
        else
            read -r -p "$prompt: " ans
        fi
        [ -n "$ans" ] || [ -z "$required" ] && break
    done
    printf -v "$var" '%s' "$ans"
}

ask_secret() {
    local var=$1 prompt=$2 required=${3-} cur isset ans
    eval "cur=\${$var-}; isset=\${$var+x}"
    if [ -n "$isset" ] && { [ -n "$cur" ] || [ -z "$required" ]; }; then return 0; fi
    while :; do
        read -r -s -p "$prompt: " ans
        echo
        [ -n "$ans" ] || [ -z "$required" ] && break
    done
    printf -v "$var" '%s' "$ans"
}

yes_no() {
    local hint=y/N ans
    [ "$2" = y ] && hint=Y/n
    read -r -p "$1 [$hint]: " ans
    case ${ans:-$2} in [Yy]*) return 0 ;; *) return 1 ;; esac
}

# A missing file is fine (new node); never fall back to another node's file.
if [ -f "$env_file" ]; then
    set -a
    # shellcheck disable=SC1090
    . "$env_file"
    set +a
fi

command -v ansible-vault >/dev/null || die "ansible not found: pipx install --include-deps ansible (or brew install ansible)"

echo "== Node ($env_file)"
ask NODE "Name (inventory + Tailscale hostname), e.g. exit-node" "" required
[[ $NODE =~ ^[A-Za-z0-9_-]+$ ]] || die "NODE: letters, digits, - and _ only"
ask NODE_HOST "IP or hostname of the node, reachable from here now" "" required
ask NODE_USER "SSH/sudo user on the node" "" required
ask NODE_TIMEZONE "Timezone of the node" "UTC" required
ask SSH_KEY "SSH private key for Ansible" "$HOME/.ssh/exit-node_ed25519" required
SSH_KEY=${SSH_KEY/#\~/$HOME}

echo
echo "== Remote access (empty = disable)"
ask DUCKDNS_DOMAIN "DuckDNS subdomain without .duckdns.org"
[[ $DUCKDNS_DOMAIN =~ ^[a-z0-9-]*$ ]] || die "DUCKDNS_DOMAIN: lowercase letters, digits and - only"
ask WG_PEERS "WireGuard clients, space separated, e.g. 'unifi phone'"
WG_ENDPOINT=${WG_ENDPOINT-}
if [ -n "$WG_PEERS" ]; then
    command -v wg >/dev/null || die "wg not found: brew install wireguard-tools"
    ask WG_PORT "WireGuard UDP port (any free UDP port on the node's public side)" 51822 required
    [[ $WG_PORT =~ ^[0-9]+$ ]] && [ "$WG_PORT" -ge 1 ] && [ "$WG_PORT" -le 65535 ] || die "WG_PORT: 1-65535"
    # Clients such as a router with tunnels to several nodes need a different subnet per node.
    ask WG_SUBNET "WireGuard /24 prefix, unique per node (e.g. 10.88.0, 10.89.0)" 10.88.0 required
    [[ $WG_SUBNET =~ ^10\.([0-9]{1,3})\.([0-9]{1,3})$ ]] && [ "${BASH_REMATCH[1]}" -le 255 ] && [ "${BASH_REMATCH[2]}" -le 255 ] \
        || die "WG_SUBNET: 10.X.Y with X, Y in 0-255"
    for p in $WG_PEERS; do
        [[ $p =~ ^[A-Za-z0-9_-]+$ ]] || die "peer '$p': letters, digits, - and _ only"
    done
    [ -z "$(printf '%s\n' $WG_PEERS | sort | uniq -d)" ] || die "WG_PEERS contains duplicates"
    if [ -z "$DUCKDNS_DOMAIN" ]; then
        ask WG_ENDPOINT "Public hostname/IP clients connect to (no DuckDNS)" "$NODE_HOST" required
    fi
fi

host_dir=host_vars/$NODE
vault_file=$host_dir/vault.yml
new_vault=0
[ -f "$vault_file" ] || new_vault=1

# Ansible's own Python: reconcile.py needs its vault and YAML libraries.
ansible_py=$(sed -n '1s/^#! *//p' "$(command -v ansible-vault)")
case $ansible_py in */env\ *) ansible_py=${ansible_py#*/env } ;; esac
# shellcheck disable=SC2086
$ansible_py -c 'import yaml, ansible.parsing.vault' 2>/dev/null \
    || die "can't find Ansible's Python (tried: $ansible_py)"

if [ "$new_vault" = 1 ]; then
    echo
    echo "== Secrets (hidden input, written only into the encrypted vault)"
    ask_secret BECOME_PASS "sudo password of $NODE_USER on the node (empty = passwordless sudo)"
    ask_secret TAILSCALE_AUTHKEY "Tailscale auth key tskey-auth-... (empty = log in manually)"
    if [ -n "$DUCKDNS_DOMAIN" ]; then
        ask_secret DUCKDNS_TOKEN "DuckDNS token" required
    fi
    ask_secret HEARTBEAT_URL "Heartbeat URL, e.g. https://hc-ping.com/... (empty = none)"
    while :; do
        read -r -s -p "New vault password for $vault_file (keep it in your password manager): " VAULT_PASS
        echo
        read -r -s -p "Repeat it: " again
        echo
        [ -n "$VAULT_PASS" ] && [ "$VAULT_PASS" = "$again" ] && break
        echo "Empty or not matching, try again."
    done
else
    read -r -s -p "Vault password for $vault_file: " VAULT_PASS
    echo
fi
[ -z "${TAILSCALE_AUTHKEY:-}" ] || [[ $TAILSCALE_AUTHKEY == tskey-* ]] || die "Tailscale auth key must start with tskey-"

echo
echo "== SSH access"
if [ ! -f "$SSH_KEY" ] && yes_no "Create SSH key $SSH_KEY?" y; then
    ssh-keygen -t ed25519 -f "$SSH_KEY" -C exit-node-ansible
fi
if [ ! -f "$SSH_KEY.pub" ]; then
    echo "No $SSH_KEY.pub; skipping key copy. Set it up before running the playbook."
elif ssh -i "$SSH_KEY" -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new \
    "$NODE_USER@$NODE_HOST" true 2>/dev/null; then
    echo "Key login to $NODE_USER@$NODE_HOST works."
elif yes_no "Key login to $NODE_USER@$NODE_HOST fails. Copy the key now (asks for the node password)?" y; then
    ssh-copy-id -i "$SSH_KEY.pub" "$NODE_USER@$NODE_HOST"
fi
if [ "$new_vault" = 1 ] && [ -z "${BECOME_PASS:-}" ] && [ -f "$SSH_KEY" ]; then
    if ssh -i "$SSH_KEY" -o BatchMode=yes -o ConnectTimeout=5 "$NODE_USER@$NODE_HOST" sudo -n true 2>/dev/null; then
        echo "Passwordless sudo works."
    else
        die "sudo on the node asks for a password (or the node is unreachable); re-run and enter it"
    fi
fi

# inventory.ini: replace this node's line, keep other nodes.
inv_line="$NODE ansible_host=$NODE_HOST ansible_user=$NODE_USER ansible_ssh_private_key_file=$SSH_KEY"
if [ -f inventory.ini ]; then
    grep -q '^\[exit_nodes\]' inventory.ini || die "inventory.ini has no [exit_nodes] group"
    { grep -v -E "^$NODE[[:space:]]" inventory.ini || true; echo "$inv_line"; } > inventory.ini.tmp
    mv inventory.ini.tmp inventory.ini
else
    printf '[exit_nodes]\n%s\n' "$inv_line" > inventory.ini
fi
echo "Wrote inventory.ini"

echo
echo "== host_vars/$NODE"
# Secrets and settings reach reconcile.py via the environment, never via argv or files.
export NODE NODE_TIMEZONE NODE_HOSTNAME DUCKDNS_DOMAIN WG_PEERS WG_PORT WG_SUBNET WG_ENDPOINT \
    BECOME_PASS TAILSCALE_AUTHKEY DUCKDNS_TOKEN HEARTBEAT_URL VAULT_PASS
# shellcheck disable=SC2086
$ansible_py scripts/reconcile.py
unset VAULT_PASS

if [ ! -f "$env_file" ] && yes_no "Save the answers to $env_file (gitignored; includes tokens, not the sudo password)?" y; then
    {
        echo "# Source of truth for $NODE: edit, then re-run scripts/setup.sh --env <this file>."
        echo "# Contains tokens: keep it out of git, back it up privately."
        for v in NODE NODE_HOST NODE_USER NODE_TIMEZONE NODE_HOSTNAME SSH_KEY DUCKDNS_DOMAIN \
            WG_PEERS WG_PORT WG_SUBNET WG_ENDPOINT TAILSCALE_AUTHKEY DUCKDNS_TOKEN HEARTBEAT_URL; do
            eval "isset=\${$v+x}; val=\${$v-}"
            if [ -n "$isset" ]; then printf '%s=%q\n' "$v" "$val"; fi
        done
    } > "$env_file"
    chmod 600 "$env_file"
    echo "Wrote $env_file"
fi

echo
ansible-galaxy collection install -r requirements.yml >/dev/null
echo "Done. Next:"
echo "  ansible-playbook site.yml --limit $NODE --ask-vault-pass"
