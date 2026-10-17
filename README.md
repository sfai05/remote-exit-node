# remote-exit-node

Ansible project that turns a small Debian box (tested target: Dell Wyse 3040, Debian 13)
into an **unmanned residential exit node** at a remote site, so you can browse from a clean,
residential IP of that location.

```mermaid
flowchart LR
    subgraph Client["Client side"]
        UniFi["Router / gateway<br/>(WireGuard client)"]
        Laptop["Laptop / phone<br/>(Tailscale or WireGuard)"]
    end
    subgraph Remote["Remote site"]
        Router["Home router<br/>UDP port-forward"]
        Node["exit node<br/>wg0 + tailscale0 + unbound"]
    end
    UniFi -- "WireGuard via DuckDNS" --> Router --> Node
    Laptop -- "Tailscale (works through any NAT)" --> Node
    Node --> Internet(("Internet<br/>with remote IP"))
```

## Features

| Track | What | Notes |
|---|---|---|
| Tailscale | Exit node + Tailscale SSH | Primary management path; works even behind CGNAT |
| WireGuard | Native server for routers (UniFi) and devices | Port, subnet and peers are settings; client configs + QR codes generated locally |
| DuckDNS | Dynamic DNS for the WireGuard endpoint | systemd timer; token never in argv or world-readable files |
| DNS | `unbound` for WireGuard clients | Lookups exit from the remote IP: no DNS leak, correct geo-CDN |
| SSH | Key-only hardening; optional `sshguard` | For "SSH via DuckDNS", prefer SSH *through* WireGuard (see below) |
| Monitoring | Hardware watchdog; optional heartbeat (healthchecks.io) carrying the node self-check, `/fail` on broken services | Alerts mean "service broken", not just "box off" |
| Doctor | `scripts/doctor.sh`: node self-check + end-to-end test of the WireGuard port forward | Run any time, and before shipping |
| LAN guard | Tunnel clients (WireGuard **and** Tailscale exit node) are blocked from the node's LAN | Private ranges + the LAN's actual IPv4/IPv6 prefixes, refreshed every 5 min |
| Baseline | BBR (node's own TCP only), IPv4/IPv6 forwarding, journald cap, low swappiness, time sync, locales, security-only auto-updates with nightly reboot | eMMC friendly, no Docker |
| Manual | `artifacts/<node>/MANUAL.md` generated on every run | Everything needed to operate the node, incl. all WireGuard client configs |

Safety defaults: tunnel clients are blocked from the remote LAN (`lan_guard_block`; verify it
with the acceptance tests in step 6), IPv6 is tunnelled (or black-holed) so it can't leak
your real location, and every secret lives in `ansible-vault` or the gitignored `.env`.

## Limitations

- **CGNAT / double NAT**: the WireGuard track needs inbound UDP to reach the node. If the
  router's WAN IP differs from `curl -4 ifconfig.me` on the remote network, the ISP uses CGNAT
  (no fix; set `enable_wireguard: false` and `enable_duckdns: false`, Tailscale still works)
  or there is a second router in front (forward the port on both). `scripts/doctor.sh` run
  from outside that network gives the definitive answer.
- **WAN IP changes**: DuckDNS follows within 5 minutes, but a router-based WireGuard client
  (e.g. UniFi) may only re-resolve the hostname when its tunnel restarts. Test this before
  relying on it; `server_keepalive` on that peer may let it recover by itself.
- Debian only (tested on 13 "trixie").
- Traffic leaves from the host's internet connection. Agree on that with them up front.

## Repository layout

```
ansible.cfg
site.yml
.env.example                   -> optional .env (gitignored) to pre-answer scripts/setup.sh
inventory.example.ini          reference; scripts/setup.sh writes inventory.ini (gitignored)
group_vars/all.yml             shared defaults + feature toggles (no secrets)
examples/host_vars/my-node/    reference; scripts/setup.sh writes host_vars/$NODE/ (gitignored)
roles/
  baseline/  ssh/  tailscale/  wireguard/  dns/  duckdns/  monitoring/  manual/
scripts/setup.sh               interactive setup: inventory, vars, encrypted vault, SSH key
scripts/wg-keys.sh             generate extra WireGuard keys as vault YAML (stdout only)
scripts/doctor.sh              health check incl. end-to-end WireGuard port-forward test
artifacts/                     generated client configs + MANUAL.md (gitignored, contain private keys)
```

## Secrets and this public repo

- `.env`, `inventory.ini`, `host_vars/`, `artifacts/` and any `vault*.yml` under `group_vars/` are gitignored.
- `.env` holds your answers including tokens (Tailscale key, DuckDNS token, heartbeat URL),
  but never the sudo password. Back it up privately (e.g. 1Password) together with the vault
  password and `artifacts/<node>/MANUAL.md`.
- Enable the pre-commit hooks (gitleaks + "vault must be encrypted"):
  `pipx install pre-commit && pre-commit install`.
- CI runs ansible-lint, a syntax check and gitleaks on every push.

## 0. What you need

| Item | Notes |
|---|---|
| Node name | e.g. `exit-node`; used for the inventory, `host_vars/`, and Tailscale hostname |
| Node host | LAN IP or hostname reachable from your Mac during setup (check: `ping -c1 <host>`). A LAN IP is the most reliable; hostnames depend on your router's DNS (UniFi registers DHCP names) or mDNS (`<name>.local`, needs `avahi-daemon` on the node) |
| Node user + sudo password | The Debian user you created at install |
| Tailscale auth key | See step 2 |
| DuckDNS subdomain + token | Free: sign in at https://www.duckdns.org (GitHub/Google/…), add a subdomain (the IP shown doesn't matter, the node updates it), copy the **token** at the top. Skip if you don't use WireGuard |
| WireGuard client names | One per device that connects without Tailscale, e.g. `unifi phone`. Each gets its own config + keys |

## 1. Prerequisites (control node)

```bash
pipx install --include-deps ansible       # or: brew install ansible
brew install wireguard-tools qrencode     # wg for key generation, qrencode for phone QR codes
```

On the node: Debian installed, SSH enabled, a sudo user. The setup script (step 3) creates
and copies the SSH key. The playbook then disables SSH password login (keep it with
`ssh_password_auth: true`), and refuses to if the login user has no `authorized_keys`.

## 2. Tailscale preparation

You need a Tailscale account (free plan is enough). No policy changes are required; the
node joins as one of your own devices.

### 2.1 Create the auth key

https://login.tailscale.com/admin/settings/keys → **Generate auth key…**

| Option | Value | Why |
|---|---|---|
| Reusable | **Off** | A one-off key is consumed on join, so a leaked vault can't add devices |
| Expiration | e.g. 7 days | Only needs to live until the first playbook run; it does **not** affect the node afterwards |
| Ephemeral | **Off** | Ephemeral nodes are deleted when offline, e.g. after a power cut |
| Pre-approved | **On** (only shown if device approval is enabled) | Nobody has to approve it remotely |

Copy the `tskey-auth-…` value right away; it is shown only once. The setup script asks for
it in step 3. Prefer a browser login? Leave it empty; the first playbook run stops at the
Tailscale step. Then run `sudo tailscale up` on the node, open the printed URL, and re-run.

### 2.2 After the first playbook run (required)

In **Machines** → the node → `…` menu:

1. **Disable key expiry.** Otherwise the node logs out after ~180 days, and on an unmanned
   box that means someone has to fix it on site.
2. **Edit route settings** → tick **Use as exit node**.

### 2.3 Use it from your devices

- Desktop / mobile app: **Exit node** → pick the node. Optionally enable
  **Allow local network access** so your own LAN (printer, NAS) keeps working.
- CLI: `tailscale set --exit-node="$NODE" --exit-node-allow-lan-access`; turn off with
  `tailscale set --exit-node=`.
- SSH: `tailscale ssh "$NODE_USER@$NODE"`.

Exit-node users can't reach the remote site's LAN (LAN guard). With the default allow-all
policy the node itself can still reach your other tailnet devices; restrict that with
Tailscale grants if you share the tailnet or worry about the box being compromised.

## 3. Configure

```bash
cp .env.example .env && code .env      # optional: pre-fill answers
scripts/setup.sh
```

The script asks for anything not set in `.env`, then:

- creates the SSH key if missing and copies it to the node if key login doesn't work yet,
- writes/updates this node's line in `inventory.ini`,
- writes `host_vars/$NODE/vars.yml` (WireGuard clients get `10.88.0.2`, `.3`, …),
- generates WireGuard keys for the server and every client,
- writes `host_vars/$NODE/vault.yml` **encrypted**. You choose the vault password here; every
  later `ansible-vault edit` / `--ask-vault-pass` asks for it, so keep it in your password manager,
- saves the answers to `.env` (including tokens, never the sudo password) and installs the
  Ansible collections.

Re-running is safe: it asks before overwriting `vars.yml` or the vault. Overwriting the vault
regenerates WireGuard keys, so existing client configs stop working.

The remaining commands in this README use the `.env` values; load them into your shell with:

```bash
set -a; . ./.env; set +a
```

To change secrets later:

```bash
EDITOR="code --wait" ansible-vault edit "host_vars/$NODE/vault.yml"   # decrypts into the editor, re-encrypts on close
```

Fine-tuning: add any setting to `host_vars/$NODE/vars.yml` (see `group_vars/all.yml` and
`roles/*/defaults/main.yml` for all):

| Variable | Default | Purpose |
|---|---|---|
| `enable_*` | see file | Turn tracks on/off |
| `wireguard_port` | `51822` | Any free UDP port on the remote router. Client configs omit `ListenPort`, so the server port can't clash with other tunnels on the client side |
| `wireguard_ipv4_network` / `_ipv6_network` | `10.88.0.0/24` / `fd88:88::/64` | Must not overlap your LAN, the remote LAN, or `100.64.0.0/10` |
| `wireguard_peers` | `[]` | One entry per client: `name`, `ipv4`, `ipv6`, keys, optional `allowed_ips`, `mtu`, `keepalive`, `server_keepalive` (set e.g. `25` on an always-on router peer only) |
| `lan_guard_block` | `true` | Block WireGuard and Tailscale exit-node clients from the node's LAN |
| `duckdns_domain` | `""` | Subdomain only |
| `node_timezone` | `UTC` | |
| `node_hostname` | `""` | Set to rename the system hostname; empty leaves it alone. The Tailscale name is `tailscale_hostname` (default: inventory name) |
| `ssh_password_auth` | `false` | SSH password login (sudo and console always accept the password) |
| `baseline_unattended_reboot` / `_time` | `true` / `04:30` | Automatic reboot after kernel updates, local time |

Adding a client later without touching existing ones: `scripts/wg-keys.sh --no-server laptop`,
paste the output under `vault_wireguard_peers` (`ansible-vault edit`), add a matching entry to
`wireguard_peers` in `vars.yml`, re-run the playbook.

## 4. Run

```bash
ansible-playbook site.yml --limit "$NODE" --ask-vault-pass
ansible-playbook site.yml --limit "$NODE" --ask-vault-pass      # second run must report changed=0
```

Client configs land in `artifacts/$NODE/<peer>.conf` (+ `.png` QR codes), mode 0600.

The last step writes `artifacts/$NODE/MANUAL.md`: login paths, router port-forward details
(with the box's MAC), instructions for the person on site, every WireGuard client config,
health checks and troubleshooting. It contains private keys; store it in your password manager.
Refresh it alone with `--tags manual`.

After the box moves to the remote site, point `ansible_host` at its Tailscale name to keep
managing it:

```bash
sed -i '' "/^$NODE /s/ansible_host=[^ ]*/ansible_host=$NODE/" inventory.ini   # macOS sed
```

## 5. Manual steps

**Before it leaves your hands**

- BIOS (Wyse 3040: F2 at boot) → Power Management → **AC Recovery = Power On**.
  Without this the box stays off after a power cut.
- Power test: unplug, wait 10 s, plug in → it rejoins the tailnet and `wg0` comes up.

**At the remote router**

- DHCP reservation for the node's MAC.
- Port-forward **UDP `wireguard_port` → node**.
- Optional, only if you need direct SSH from the internet: forward a high TCP port
  (e.g. 22022) → node:22 and set `enable_ssh_public: true` (installs sshguard).
  Usually unnecessary: connect WireGuard, then `ssh "$NODE_USER@10.88.0.1"`. That exposes
  nothing but one UDP port, which doesn't answer unauthenticated packets.
- Reaching the router's admin page later needs no subnet route: tunnel through the node with
  `ssh -L 8080:<router-ip>:80 "$NODE_USER@$NODE"` and open http://localhost:8080.

**UniFi gateway (client side)**

- Settings → VPN → VPN Client → Create New → WireGuard → upload one client config, e.g.
  `artifacts/$NODE/unifi.conf` (also included in `MANUAL.md`).
- The config has no `ListenPort` on purpose: the client then uses a random local port, so it
  can't collide with other WireGuard tunnels on the gateway (`EADDRINUSE`, stuck on "Connecting").
- Settings → Routing → Traffic Routes → send chosen devices/domains through the new client.
- If the import rejects IPv6, remove `ipv6` from the `unifi` peer and set
  `allowed_ips: 0.0.0.0/0`. Then disable IPv6 for the routed devices, or their IPv6
  traffic will bypass the tunnel.

## 6. Verify

```bash
scripts/doctor.sh                 # node self-check + WireGuard port-forward test
```

The port-forward test sends a few UDP probes to the DuckDNS endpoint and checks that the
node counted them. Run it from **outside** the remote network (e.g. a phone hotspot);
from inside, most routers don't loop traffic back and the result is inconclusive. The node
also runs the self-check in every heartbeat (`exit-node-doctor` on the node).

Acceptance tests before the box leaves your hands, and again on site:

| Test | Expected |
|---|---|
| `scripts/doctor.sh` from another network | No FAIL; port forward OK |
| From each tunnel (WireGuard, Tailscale exit node): `curl -4 ifconfig.me` | The remote site's IP |
| From each tunnel: `curl -6 ifconfig.me` | The remote site's IPv6, or a failure. **Never your own** |
| From each tunnel: open the remote router's admin page and ping a LAN device, IPv4 and IPv6 | Blocked (timeout) |
| https://dnsleaktest.com through each tunnel | Only resolvers at the remote site |
| Pull the power, wait 10 s, plug in | Both paths back within ~3 min, `scripts/doctor.sh` clean |
| Change the remote WAN IP (router reconnect) | DuckDNS follows; note whether the router client recovers by itself |

You can still reach the remote router yourself: `ssh -L` tunnels start on the node itself, so
the LAN guard (which only filters forwarded tunnel traffic) doesn't affect them.

## Troubleshooting

- **UniFi stuck on "Connecting"**: run `scripts/doctor.sh` from outside the remote network;
  it tells port forward, DuckDNS and CGNAT apart.
- **Router client down after the remote IP changed**: toggle the VPN client off and on, or
  set `server_keepalive: 25` on that peer.
- **Slow / stalled pages over WireGuard**: MTU. Set `wireguard_mtu: 1380` (or per peer `mtu`).
- **Tailscale re-join**: auth keys expire (90 days max). Once joined the node stays joined;
  only a fresh install needs a new key in the vault.
