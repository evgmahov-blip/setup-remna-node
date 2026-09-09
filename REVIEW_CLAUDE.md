# Final review brief: RemnaNode NEXT

## Review target

Review the current HEAD of branch:

`fix/xhttp-raw-hysteria-from-july7`

Base branch:

`custom`

Do not merge as part of this review. The goal is a final safety/architecture verdict before production merge.

See also `REVIEW_CHECKLIST.md` for the final live-validation checklist.

The last full independent review was performed on `9e28ca3b63ddce2b93704db3d9a1af210d843261` and returned `MERGE: YES` with no BLOCKER/HIGH. Changes after that commit are a deliberately small hardening delta addressing agreed M-1/M-2/M-3/M-4/M-5 items; review the delta rather than reopening unrelated architecture.

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
- Runtime module commit: `bc8d41270ee43ad770403c07028706e3454e13cc`
- Node templates: `845187fbee8fff72f66d1570af436438e859e40d`
- STREAM source: `ec5ffa5c26e57c6f6b2060bbf6743d3921c05500`

Verify `production/modules.sha256` and the hard-coded hashes in `setup_node_next.sh` agree with the immutable runtime module commit.

## Post-audit hardening delta

The following changes are intentionally limited in scope and must not alter the July dataplane:

1. STREAM uses a persistent per-node 8-hex salt in `$APP_DIR/.selfsteal_stream_salt`. The salt is used in browser-visible catalog/history paths and published audio filenames. The logical cache filenames remain stable.
2. The six production STREAM audio files are pinned by SHA256. Production cache/download validation is fail-closed; `STREAM_AUDIO_FIXTURE_DIR` remains a CI-only exception. Unknown logical names do not bypass production checksum validation.
3. `STREAM_AUDIO_MAX_BYTES` defaults to 8 MiB and `curl --max-filesize` enforces the download cap. July nginx is deliberately unchanged.
4. `setup_node_next.sh` takes an APP_DIR-scoped nonblocking `flock` before the first mutating preflight action so concurrent NEXT runs cannot race webroot/compose/firewall operations.
5. Hysteria cert-bind recovery is gated by the exact local `.transport` values `hysteria` or `combined`; `xhttp`, `raw`, missing or invalid markers return without touching compose/docker.
6. `fetch_static()` disallows redirect downgrade with `--proto-redir '=https'`, and SelfSteal validates `WWW_DIR` as a non-root absolute canonical path before recursive cleanup.

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

- run recovery only when local `.transport` is exactly `hysteria` or `combined`
- no broad Docker restart when only the cert bind needs repair
- preserve/restore the certificate mount safely
- rollback on failed recovery
- do not claim `.transport` is necessarily the Config Profile currently assigned in the Remnawave panel; it is only the last locally generated transport marker

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

The abandoned Radio Book reverse-proxy experiment has been removed from the branch. Production STREAM uses only local same-origin audio files.

Expected STREAM runtime:

- exactly six local channels
- three Russian LibriVox/Tolstoy audio files
- Beethoven, Chopin and Bach local audio files
- browser-visible paths only under `/audio/...` and salted `/data/streams-<salt>.json`, `/data/history-<salt>.json`
- published audio names include the persistent per-node salt, e.g. `/audio/bach-air-<salt>.mp3`
- no runtime DeepBeat, Radio Book, Archive.org or Wikimedia origins exposed to the browser
- `STREAM_ORIGIN = window.location.origin`
- `active` and `listeners` runtime identifiers protected from `uniquify-theme`
- failed build/uniquify/runtime validation must preserve the existing webroot

### Operator-attested production audio pins from USA2

These hashes were measured by the operator from the live USA2 cache and are intentionally treated as production pins:

- `tolstoy-teachings-ch01.mp3`: `d71d3070a7790898121e7cbe4c0d67af41eb93964ff449dbec5abe570435e994` (4,012,659 bytes)
- `tolstoy-childhood-ch01.mp3`: `ac399678d5b408f08864e9e7f5c40da039a090a66eba73d4852c570dbb44d8fe` (5,844,032 bytes)
- `anna-karenina-ch01.mp3`: `40f93935542d995092bfde517f919ab7efb8b46afa75284184f281ca0e5201e5` (3,004,928 bytes)
- `beethoven-moonlight.mp3`: `01e2b9902a4a0f3f73af4ffd9eac9769391065fd8fafe48fb49f929454e0ce86` (6,437,194 bytes)
- `chopin-nocturne.mp3`: `f65c98447a4212afe77878771e5279f230cfe74173139721dd0fe412982058f2` (3,205,087 bytes)
- `bach-air.mp3`: `e9bbe80f87e98c0b263208cb8e333f644662d2f607a1436798f9981138783c27` (4,856,606 bytes)

Total live audio webroot observed before the salted-path delta: about 27 MiB. Largest individual file: about 6.14 MiB.

### Live validation completed on USA2 before the final hardening delta

The production STREAM path was installed through the normal `remnanode-next -> 7 -> 1` menu on `usa2.remna.2rdp.ru` after the Radio Book experiment was removed.

Operator confirmed the page and audio playback worked correctly. Because the final hardening delta changes browser-visible catalog/audio paths, one short repeat of `7 -> 1` and browser playback is required after CI passes on the new HEAD.

Earlier live diagnostics also confirmed that a one-time stale Docker file bind issue was repaired by recreating only `remnawave-nginx`; Xray/rw-core was not restarted. That stale-bind repair is historical live state, not a required STREAM runtime mechanism.

## NEXT wrapper and lifecycle safety

Entrypoint:

`setup_node_next.sh`

Review:

- immutable fetch/checksum behavior
- APP_DIR-scoped `flock` is acquired before any preflight mutation
- legacy July adaptation
- no unsafe `/usr/local/bin/remnanode` bypass
- safe local `/usr/local/bin/remnanode-next` launcher
- cancelled uninstall behavior
- partial/failed uninstall cleanup
- recovery after legacy installer failure
- no unnecessary restart/recreate of Xray/rw-core
- quoting, temp files, traps/races and rollback paths

Telemt remains disabled in NEXT because its historical host-nginx `stream`/`ssl_preread` deployment conflicts with Xray ownership of public TCP/443.

## Accepted residual risks to reassess

Please explicitly state whether these remain acceptable or should block merge:

1. inherited July Xray release asset is versioned but does not have an additional independently pinned checksum;
2. SelfSteal directory publication is fail-closed for build/validation failures but is not fully power-loss atomic across webroot replacement;
3. `.transport` is the last locally generated transport marker, not proof of which Config Profile is assigned in Remnawave Panel; the new Hysteria gate reduces false recovery but cannot eliminate that information gap;
4. salted STREAM paths reduce blind exact-path fleet scanning, but the six works, metadata, bitrates, file bytes and Content-Length remain fleet-constant; correlation of already-suspected domains remains an accepted LOW;
5. STREAM audio remains unauthenticated static content and nginx has no per-client rate limit. The live set is about 27 MiB, future individual assets are capped at 8 MiB, and download ingestion is capped with `curl --max-filesize`; bandwidth abuse is an accepted residual risk rather than a claimed fix. July nginx is intentionally not patched in this PR.

## CI and live evidence

Historical green checkpoint `d54dfbbffda30b15711529e3192410bf4a9cc6fd` passed all six current workflows before the final hardening delta.

The final hardening delta must pass all six workflows on its exact current HEAD:

- `inbound-name-ci`
- `selfsteal-site-ci`
- `transport-profile-ci`
- `rkn-safe-ci`
- `runtime-guards-ci`
- `round4-regressions-ci`

The former experimental `stream-safe-audio-manager.sh` and its CI workflow were removed because Radio Book is no longer part of the production design.

## Desired final output

For the post-audit delta review, return:

- `DELTA: ACCEPT` or `DELTA: REJECT`
- BLOCKER
- HIGH
- MEDIUM only if newly introduced by the delta
- VERIFIED OK
- remaining live checks, if any

Do not reopen already accepted unrelated LOW/residual risks unless this delta changes their assumptions. For every BLOCKER/HIGH finding, give the exact file/function/field and the smallest correction that preserves the July dataplane architecture.
