# Claude review brief: RemnaNode July baseline + XHTTP / RAW / Hysteria2 / SNI / RKN Watcher

## Goal

Review branch `fix/xhttp-raw-hysteria-from-july7` as a safety/architecture audit before production deployment.

The non-negotiable requirement is to preserve the known-working July 7 architecture and add new functionality around it rather than replace its dataplane.

## Stable baseline

Pinned baseline commit:

`34aeaa99aa1a5c21fc4f9d0c976d38607d025353`

`setup_node_next.sh` launches that exact baseline for legacy installation/management. The baseline must remain the source of truth for:

- Remnawave node installation
- Docker host networking
- SelfSteal nginx
- `/dev/shm/nginx.sock`
- SSL handling
- UFW
- Xray version management
- Telemt integration
- diagnostics/logs

Do not reintroduce an nginx `stream` listener in front of Xray on public TCP/443.

## Required dataplane invariant

For TCP transports, public TCP/443 belongs to Xray/rw-core, not nginx.

Stable SelfSteal flow:

```text
Internet TCP/443
      |
      v
Xray/rw-core
      |
      +-- valid VPN client -> proxy
      |
      +-- REALITY SelfSteal target -> /dev/shm/nginx.sock
                                  |
                                  v
                         nginx decoy website
```

The nginx SelfSteal server in the July baseline listens on the Unix socket with PROXY protocol support.

## New transport manager

File:

`production/remnawave-transport-manager.sh`

It generates Remnawave Config Profile JSON + Host field hints for three alternatives:

1. VLESS + REALITY + XHTTP
2. VLESS + REALITY + RAW
3. Hysteria2 + TLS

### REALITY camouflage modes

For XHTTP and RAW, there are two explicit modes.

#### SelfSteal mode (default / stable architecture)

- `target`: `/dev/shm/nginx.sock`
- `xver`: `1`
- `serverNames`: node domain
- client Host SNI: node domain
- uses the existing local SelfSteal website and node certificate

This mode is intended to preserve the original architecture.

#### External SNI mode

- target is an external HTTPS site, for example `www.microsoft.com:443`
- SNI comes from a validated external pool
- `xver`: `0`
- current working SNI is never automatically rotated
- updating the SNI list must not alter the current SNI

External pool source currently used:

`https://raw.githubusercontent.com/evkir/reality-probe/main/reality_probe.py`

Please verify parsing, TLS 1.3 validation, certificate hostname validation, and failure behavior.

## Hysteria2

Hysteria2 uses:

- protocol `hysteria`
- transport `hysteria`
- version 2
- TLS
- UDP/443
- ALPN h3

The generated Hysteria masquerade embeds the current `/var/www/html/index.html` as a `string` masquerade so it does not require mounting the website directory inside rw-core.

Please verify that this is valid for the current Xray-core schema and Remnawave Config Profiles.

## SNI safety requirements

Must hold:

- no scheduled/random automatic change of a working SNI
- no SNI change caused only by refreshing the candidate list
- private REALITY key must never be printed in Host hints
- REALITY public key and short ID may be shown
- changing camouflage mode must regenerate a profile; it must not silently mutate the live Remnawave panel configuration

## RKN Watcher

Manager:

`production/rkn-watcher-manager.sh`

Pinned upstream repository:

`Balbuto/RKN-Watcher`

Pinned upstream commit:

`558fc11a0792892927785e162359585d51972a6a`

Requirements:

- verify upstream SHA256SUMS before running
- do not automatically apply firewall policy during normal node install
- display panel IP, current SSH client IP and node control port before manual apply
- explicit confirmation before `apply`
- avoid locking out SSH or Remnawave control port

## Unified menu

Entrypoint:

`setup_node_next.sh`

It intentionally keeps the July installer separate and pinned while exposing new modules in a color-separated menu.

Please specifically review:

1. Whether XHTTP + REALITY + local Unix-socket SelfSteal is valid with current Xray-core.
2. Whether RAW + REALITY + local Unix-socket SelfSteal is valid with current Xray-core.
3. Whether `xver: 1` is correct for the July nginx `proxy_protocol` Unix socket listener.
4. Whether Hysteria2 schema and TLS/masquerade fields are correct.
5. Whether generated Remnawave Config Profiles use fields compatible with current Remnawave.
6. Whether Remnawave dynamically injecting users into `clients: []` / `users: []` works for all three inbounds.
7. Whether the Host field hints match current Remnawave inheritance behavior.
8. Whether any port collision exists when TCP/443 is XHTTP/RAW and UDP/443 is Hysteria2.
9. Whether SNI candidate validation is sufficient.
10. Any shell-safety, quoting, race, update, firewall or rollback bugs.

## Important historical failure to avoid

A previous experimental branch placed nginx `ssl_preread` in front of Xray on public TCP/443 and routed REALITY by SNI to an internal Xray port. That experiment broke working client connectivity and must not be reintroduced into this branch.

## Desired review output

Please provide findings grouped as:

- BLOCKER
- HIGH
- MEDIUM
- LOW
- VERIFIED OK

For every blocker/high issue, provide the exact file/function/JSON field and a minimal correction that preserves the July dataplane architecture.
