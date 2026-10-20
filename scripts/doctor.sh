#!/usr/bin/env bash
# Health check from the control node: runs the node self-check and checks that UDP probes
# sent to the WireGuard endpoint reach the node.
# Usage: scripts/doctor.sh [--env FILE] [ssh-host]   (defaults: .env, its NODE_HOST)
set -euo pipefail

env_file=.env
host_arg=""
while [ $# -gt 0 ]; do
    case $1 in
        --env) [ $# -ge 2 ] || { echo "--env needs a file" >&2; exit 64; }; env_file=$2; shift 2 ;;
        -*) echo "usage: $0 [--env FILE] [ssh-host]" >&2; exit 64 ;;
        *) host_arg=$1; shift ;;
    esac
done
case $env_file in /*) ;; *) env_file="$PWD/$env_file" ;; esac
cd "$(dirname "$0")/.."

if [ -f "$env_file" ]; then
    set -a
    # shellcheck disable=SC1090
    . "$env_file"
    set +a
elif [ -z "$host_arg" ]; then
    echo "$env_file not found; pass --env FILE or an ssh host" >&2
    exit 64
fi

host=${host_arg:-${NODE_HOST:-}}
[ -n "$host" ] || { echo "usage: $0 [--env FILE] <ssh-host> (or set NODE_HOST in the env file)" >&2; exit 64; }
target="${NODE_USER:+$NODE_USER@}$host"
ssh_opts=(-o ConnectTimeout=10)
[ -z "${SSH_KEY:-}" ] || ssh_opts+=(-i "${SSH_KEY/#\~/$HOME}")

remote() { ssh "${ssh_opts[@]}" "$target" sudo -n /usr/local/sbin/exit-node-doctor "$@"; }

echo "== Node self-check ($target)"
if report=$(remote 2>&1); then rc=0; else rc=$?; fi
if [ "$rc" -eq 255 ]; then
    echo "FAIL  cannot reach $target over SSH. Try the other path (Tailscale name vs the WireGuard server IP)."
    exit 2
fi
if ! printf '%s\n' "$report" | grep -qE '^(OK|INFO|WARN|FAIL) '; then
    printf '%s\n' "$report"
    echo "FAIL  self-check not available on the node; re-run the playbook."
    exit 2
fi
printf '%s\n' "$report"

if [ -n "${WG_PEERS:-}" ]; then
    endpoint=${WG_ENDPOINT:-}
    [ -n "$endpoint" ] || endpoint="${DUCKDNS_DOMAIN}.duckdns.org"
    port=${WG_PORT:-51822}
    echo
    echo "== WireGuard reachability (UDP $port via $endpoint)"
    before=$(remote probe-count)
    # 777-byte payloads: no valid WireGuard packet has this size, so only probes are counted.
    for _ in 1 2 3 4 5; do
        head -c 777 /dev/zero | nc -u -w1 "$endpoint" "$port" >/dev/null 2>&1 || true
    done
    sleep 1
    after=$(remote probe-count)
    node_ip=$(printf '%s\n' "$report" | sed -n 's/^INFO  public IPv4: //p')
    my_ip=$(curl -4 -fsS -m 5 https://ifconfig.me 2>/dev/null || true)

    if [ "${after:-0}" -gt "${before:-0}" ]; then
        echo "OK    probes reached the node on UDP $port."
        echo "      This doesn't prove a working tunnel; connect a client and check its handshake above."
    elif [ -n "$my_ip" ] && [ "$my_ip" = "$node_ip" ]; then
        echo "WARN  inconclusive: this machine shares the node's public IP ($my_ip)."
        echo "      Routers often don't loop traffic back to themselves; re-run from another network (e.g. phone hotspot)."
        [ "$rc" -ge 1 ] || rc=1
    else
        echo "FAIL  probes did not reach the node. Check, in order:"
        echo "      1. inbound UDP $port: home router port forward to the node, or the provider"
        echo "         firewall for a VM (e.g. OCI security list / NSG)"
        echo "      2. the node's own firewall: 'iptables: exit-node rules' in the self-check, if shown"
        echo "      3. the endpoint ($endpoint) resolves to the node's current public IP"
        echo "      4. behind a home router: CGNAT or double NAT (router WAN IP differs from the public IPv4 above)"
        rc=2
    fi
fi

exit "$rc"
