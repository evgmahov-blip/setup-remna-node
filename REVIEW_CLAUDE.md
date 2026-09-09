# Final review brief: RemnaNode NEXT

## Review target

Review the current HEAD of branch:

`fix/xhttp-raw-hysteria-from-july7`

Base branch:

`custom`

Do not merge as part of this review. The goal is a final safety/architecture verdict before production merge.

## Non-negotiable dataplane invariant

The known-working July 7 architecture must remain intact.

Pinned July baseline:

`34aeaa99aa1a5c21fc4f9d0c976d38607d025353`

For TCP transports, public TCP/443 belongs to Xray/rw-core, never to host nginx.

Expected SelfSteal flow:

```text
Internet TCP/443
      |
      v
Xray/rw-core
      |
      +-- valid client -> proxy
      |
      +-- REALITY SelfSteal -> /dev/shm/nginx.sock
                               |
                               v
                         nginx decoy site
```

The July nginx Unix socket uses PROXY protocol. Do not reintroduce host nginx `stream` / `ssl_preread` in front of Xray.

## Immutable runtime pins

- July baseline: `34aeaa99aa1a5c21fc4f9d0c976d38607d025353`
- Runtime module commit: `9f079a38fdc819765eec6c906ffc5a72a443c9ea`
- Node templates: `845187fbee8fff72f66d1570af436438e859e40d`
- STREAM source: `ec5ffa5c26e57c6f6b2060bbf6743d3921c05500`

Verify `production/modules.sha256` and the hard-coded hashes in `setup_node_next.sh` agree.

## Transport manager

Primary manager:

`production/remnawave-transport-manager.sh`

Supported profiles:

1. VLESS + REALITY + XHTTP on TCP/443
2. VLESS + REALITY + RAW on TCP/443
3. Hysteria2 + TLS on UDP/443
4. XHTTP TCP/443 + Hysteria2 UDP/443 combined

Review:

- XHTTP + REALITY schema and current Xray compatibility
- RAW + REALITY schema
- Hysteria2 schema, TLS certificate mount, ALPN and UDP/443 behavior
- combined TCP/443 + UDP/443 collision safety
- Remnawave user injection into generated inbounds
- Host hints and generated inbound naming
- blank/default `minClientVer` handling
- XHTTP signature remains opt-in and does not silently alter unrelated profiles

Expected fleet naming from node domains includes examples such as:

- `usa2...` -> `USA-node2-xHTTP`, `USA-node2-RAW`, `USA-node2-Hysteria2`
- `fin2...` -> `FIN-node2-xHTTP`, `FIN-node2-RAW`, `FIN-node2-Hysteria2`

## REALITY camouflage

SelfSteal mode must use the local Unix socket and preserve the July architecture.

External SNI mode must not automatically rotate a currently working SNI. Refreshing candidate lists must not mutate the active profile or Remnawave panel configuration.

Review TLS/certificate validation and failure behavior for external candidates.

## Hysteria2 recovery

Review `production/next-runtime-guards.sh` and the Hysteria certificate bind recovery path.

Requirements:

- no broad Docker restart when only the cert bind needs repair
- preserve/restore the certificate mount safely
- rollback on failed recovery
- do not claim the locally generated profile is necessarily the profile currently assigned in the Remnawave panel

## RKN Watcher

Manager:

`production/rkn-watcher-manager.sh`

Pinned upstream:

`Balbuto/RKN-Watcher@558fc11a0792892927785e162359585d51972a6a`

Review SAFE scanner guard behavior, allow-list logic, update lease, systemd self-heal, UFW reload recovery, uninstall cleanup and rollback behavior.

Important invariant: failure or partial uninstall must never leave an active self-heal mechanism that recreates firewall state after uninstall.

## SelfSteal / STREAM

Production manager:

`production/selfsteal-site-manager.sh`

The abandoned Radio Book reverse-proxy experiment has been removed from the branch. Production STREAM now uses only local same-origin audio files.

Expected STREAM runtime:

- exactly six local channels
- three Russian LibriVox/Tolstoy audio files
- Beethoven, Chopin and Bach local audio files
- browser-visible paths only under `/audio/...`, `/data/streams.json`, `/data/history.json`
- no runtime DeepBeat, Radio Book, Archive.org or Wikimedia origins exposed to the browser
- `STREAM_ORIGIN = window.location.origin`
- `active` and `listeners` runtime identifiers protected from `uniquify-theme`
- failed build/uniquify/runtime validation must preserve the existing webroot

### Live validation completed on USA2

The final production STREAM path was installed through the normal `remnanode-next -> 7 -> 1` menu on `usa2.remna.2rdp.ru` after the Radio Book experiment was removed.

Operator confirmed the final page and audio playback work correctly.

Earlier live diagnostics also confirmed that a one-time stale Docker file bind issue was repaired by recreating only `remnawave-nginx`; Xray/rw-core was not restarted. That stale-bind repair is historical live state, not a required STREAM runtime mechanism.

## NEXT wrapper and lifecycle safety

Entrypoint:

`setup_node_next.sh`

Review:

- immutable fetch/checksum behavior
- legacy July adaptation
- no unsafe `/usr/local/bin/remnanode` bypass
- safe local `/usr/local/bin/remnanode-next` launcher
- cancelled uninstall behavior
- partial/failed uninstall cleanup
- recovery after legacy installer failure
- no unnecessary restart/recreate of Xray/rw-core
- quoting, temp files, traps/races and rollback paths

Telemt remains disabled in NEXT because its historical host-nginx `stream`/`ssl_preread` deployment conflicts with Xray ownership of public TCP/443.

## Previously accepted residual risks to reassess

Please explicitly state whether these remain acceptable or should block merge:

1. inherited July Xray release asset is versioned but does not have an additional independently pinned checksum;
2. SelfSteal directory publication is fail-closed for build/validation failures but is not fully power-loss atomic across webroot replacement;
3. a stale local Hysteria profile can conservatively trigger cert-bind recovery because the node cannot know which Config Profile is actually assigned in the Remnawave panel.

## CI and live evidence

Production checkpoint `d54dfbbffda30b15711529e3192410bf4a9cc6fd` passed all six current workflows:

- `inbound-name-ci`: SUCCESS
- `selfsteal-site-ci`: SUCCESS
- `transport-profile-ci`: SUCCESS
- `rkn-safe-ci`: SUCCESS
- `runtime-guards-ci`: SUCCESS
- `round4-regressions-ci`: SUCCESS

Commits after that checkpoint only adjust this final-review brief; reviewers should still inspect CI status on the current branch HEAD.

The former experimental `stream-safe-audio-manager.sh` and its CI workflow were removed before the green checkpoint because Radio Book is no longer part of the production design.

## Desired final output

Return:

- `MERGE: YES` or `MERGE: NO`
- BLOCKER
- HIGH
- MEDIUM
- LOW
- VERIFIED OK
- remaining live checks, if any

For every BLOCKER/HIGH finding, give the exact file/function/field and the smallest correction that preserves the July dataplane architecture.
