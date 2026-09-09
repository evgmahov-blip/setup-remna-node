# REMNANODE NEXT — production installer

Production installer and management CLI for Remnawave nodes on Ubuntu/Debian.

The current production path is **`setup_node_next.sh` / `remnanode-next`**. The historical `setup_node.sh` is retained only as the pinned July base used internally by NEXT and should not be used as the normal operator entrypoint.

## Production status

- Live old-node canary: **PASS**.
- A real client connected and carried traffic after the upgrade.
- Public TCP/443 remains owned by Xray/rw-core.
- nginx remains behind `/dev/shm/nginx.sock` with PROXY protocol.
- No host nginx `stream` / `ssl_preread` layer is inserted in front of Xray.
- Telemt / MTProto is disabled in NEXT because its historical host-nginx mode conflicts with Xray ownership of public TCP/443.
- RKN scanner protection uses a dedicated chain and safe rollback/restore/update logic.
- Runtime modules are fetched from an immutable commit and verified by SHA256.

See `CANARY_ACCEPTANCE_2026-09-09.md` for the final live acceptance record.

## Supported transport profiles

NEXT generates Remnawave Config Profiles and Host hints for:

- **XHTTP + REALITY** — TCP/443
- **RAW + REALITY** — TCP/443
- **Hysteria2 + TLS** — UDP/443
- **XHTTP + Hysteria2** — TCP/443 + UDP/443

XHTTP signature support is opt-in. REALITY `minClientVer` is operator-controlled; leaving it blank keeps the Xray default.

> Hysteria2/QUIC uses TLS 1.3 semantics. The TLS 1.2 preference used for ordinary HTTPS traffic is not forced onto Hysteria2.

## SelfSteal

NEXT keeps nginx behind the Xray fallback Unix socket and supports multiple decoy-site modes.

The production STREAM mode is local-only at browser runtime:

- exactly six local audio channels;
- browser-visible audio/catalog/history paths are salted per node;
- production audio assets are SHA256-pinned;
- each source download is capped at 8 MiB;
- no browser dependency on Archive.org, Wikimedia, RadioBook or other runtime origins;
- `active` and `listeners` runtime tokens are protected from theme mutation.

Accepted residual: the same static audio content can still be correlated by content/hash across already-suspected nodes. There is no nginx per-client rate limit for the static audio files.

## RKN safe scanner guard

The RKN integration is intentionally narrow:

- dedicated `REMNA_RKN_SCANNERS` chain;
- known scanner set only;
- DROP only for tcp/80, tcp/443 and udp/443;
- current SSH IPv4 and panel IPv4 are allowed before scanner DROP rules;
- node control port is checked before activation;
- 120-second rollback protects first activation;
- permanent mode enables boot restore and randomized daily updates;
- list updates use sanity checks and last-good rollback;
- `[Y/n]` input is normalized for CR/whitespace/case and invalid input is re-prompted instead of silently becoming `No`.

## Immutable production set

July base:

```text
34aeaa99aa1a5c21fc4f9d0c976d38607d025353
```

Production code merge/freeze commit:

```text
e8fb95d2b9df06bb96625850409cd922606b055d
```

Immutable runtime module commit pinned by the wrapper:

```text
5e54fd49e7b8500fe337f5df442bfa568075a147
```

Important module checksums:

```text
RKN manager:
283414299df4e12e3d12b586ab71b1278968fa77c5ebf85eb61f37ee5bcf68e9

NEXT runtime guards:
620797d0677d091d6550894e32fea58ce7f2adf2f125d6f6ccfb217a7b3382fd

SelfSteal manager:
b783e94f2ef3764b2e397cba9eb96aeab88d7da11da017a2c867054f9546a84a
```

The wrapper verifies runtime modules against embedded SHA256 values before execution.

## Quick start

Run as root, or download with your normal user and execute with `sudo`:

```bash
curl -fsSLo /tmp/setup_node_next.sh \
  https://raw.githubusercontent.com/evgmahov-blip/setup-remna-node/custom/setup_node_next.sh
sudo bash /tmp/setup_node_next.sh
```

After the first normal file-based run, the supported global command is:

```bash
remnanode-next
```

Do **not** use `remnanode` as the management command. NEXT removes that legacy global command because it bypasses NEXT post-processing and safety guards.

For a reproducible audit run of the frozen production code, download the wrapper from the exact production merge commit instead of the moving `custom` branch:

```bash
curl -fsSLo /tmp/setup_node_next.sh \
  https://raw.githubusercontent.com/evgmahov-blip/setup-remna-node/e8fb95d2b9df06bb96625850409cd922606b055d/setup_node_next.sh
sudo bash /tmp/setup_node_next.sh
```

The wrapper at that commit still fetches its production runtime modules from the immutable module commit `5e54fd49e7b8500fe337f5df442bfa568075a147` and verifies their checksums.

## Main NEXT menu

`remnanode-next` exposes the supported operator surface:

1. installation and normal node management through the pinned July base;
2. consolidated node/ports/module status;
3. generation of XHTTP / RAW / Hysteria2 / combined profiles and Host hints;
4. viewing/copying generated profiles;
5. XHTTP signature management;
6. REALITY SNI status;
7. SelfSteal site management;
8. RKN Watcher safe scanner guard management.

The nested July menu is adapted by NEXT. Its `0` entry is shown as **“Назад в REMNANODE NEXT”**, not as a shell/session exit.

## Safety model

NEXT intentionally keeps the July dataplane and adds deterministic post-processing rather than replacing the public 443 architecture.

Key guards include:

- immutable July source + checksum;
- immutable runtime module commit + per-module checksums;
- process-lifetime APP_DIR lock to prevent concurrent mutating NEXT runs;
- generated profile validation with Xray/rw-core before atomic install;
- Hysteria cert-bind recovery only for local `.transport = hysteria|combined`;
- RKN update lease, sanity checks and last-good recovery;
- SelfSteal fail-closed publication and guarded webroot cleanup;
- no automatic host-nginx takeover of TCP/443;
- legacy global `remnanode` bypass removed.

## CI and review

Before production merge, the exact PR head passed all six production workflows:

- `inbound-name-ci`
- `selfsteal-site-ci`
- `transport-profile-ci`
- `rkn-safe-ci`
- `runtime-guards-ci`
- `round4-regressions-ci`

All six also passed again on the exact merge commit on `custom`.

An independent external review of the pre-final-hardening checkpoint returned **MERGE: YES** with no BLOCKER/HIGH findings. The subsequent hardening delta and accepted residuals are documented in `REVIEW_CLAUDE.md` and the final live acceptance is documented in `CANARY_ACCEPTANCE_2026-09-09.md`.

## Live validation note

The old-node installation/upgrade canary is complete and passed, including real client traffic. The earlier USA2 STREAM page/audio test was completed before the final salted public-path delta. The salted final STREAM implementation is covered by checksum/size/path CI, but a separate post-delta USA2 browser playback was not independently re-run from the GitHub automation environment; this is intentionally recorded rather than claimed as performed.

## Requirements

- Ubuntu or Debian
- root privileges for installation/management
- Docker / Docker Compose (installed by the July base when required)
- a Remnawave node certificate/secret for initial node registration
- node domain and panel IPv4 for normal installation
- DNS/HTTP validation prerequisites when using Certbot Standalone

## Files of interest

- `setup_node_next.sh` — production wrapper / CLI
- `setup_node.sh` — historical July implementation retained as immutable internal base; not the normal production entrypoint
- `production/remnawave-transport-manager.sh`
- `production/xhttp-signature-manager.sh`
- `production/rkn-watcher-manager.sh`
- `production/selfsteal-site-manager.sh`
- `production/network-tuning-manager.sh`
- `production/next-runtime-guards.sh`
- `production/modules.sha256`
- `CANARY_ACCEPTANCE_2026-09-09.md`
- `REVIEW_CLAUDE.md`
- `REVIEW_CHECKLIST.md`

## License

See `LICENSE.txt`.
