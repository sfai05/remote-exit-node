#!/usr/bin/env bash
# Health check from the control node: runs the node self-check and tests the WireGuard
# port forward end to end (probe packets sent here must arrive at the node).
# Usage: scripts/doctor.sh [ssh-host]   (default: NODE_HOST from .env)
set -euo pipefail
cd "$(dirname "$0")/.."

if [ -f .env ]; then
    set -a
    # shellcheck disable=SC1091
    . ./.env
    set +a
fi

host=${1:-${NODE_HOST:-}}
[ -n "$host" ] || { echo "usage: $0 <ssh-host> (or set NODE_HOST in .env)" >&2; exit 64; }
target="${NODE_USER:+$NODE_USER@}$host"
ssh_opts=(-o ConnectTimeout=10)
[ -z "${SSH_KEY:-}" ] || ssh_opts+=(-i "${SSH_KEY/#\~/$HOME}")

remote() { ssh "${ssh_opts[@]}" "$target" sudo -n /usr/local/sbin/exit-node-doctor "$@"; }

echo "== Node self-check ($target)"
if report=$(remote 2>&1); then rc=0; else rc=$?; fi
if [ "$rc" -eq 255 ]; then
    echo "FAIL  cannot reach $target over SSH. Try the other path (Tailscale name vs 10.88.0.1 over WireGuard)."
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
    echo "== WireGuard port forward (UDP $port via $endpoint)"
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
        echo "OK    probes reached the node on UDP $port: the router forwards the port."
        echo "      This doesn't prove a working tunnel; connect a client and check its handshake above."
    elif [ -n "$my_ip" ] && [ "$my_ip" = "$node_ip" ]; then
        echo "WARN  inconclusive: this machine shares the node's public IP ($my_ip)."
        echo "      Routers often don't loop traffic back to themselves; re-run from another network (e.g. phone hotspot)."
        [ "$rc" -ge 1 ] || rc=1
    else
        echo "FAIL  probes did not reach the node. Check, in order:"
        echo "      1. router port forward: UDP $port -> node's LAN IP, port $port"
        echo "      2. DuckDNS points to the current WAN IP (see the self-check above)"
        echo "      3. CGNAT or double NAT: router WAN IP differs from the public IPv4 above"
        rc=2
    fi
fi

exit "$rc"
