# Final production checklist

## Architecture

- [x] July dataplane architecture preserved.
- [x] Public TCP/443 remains owned by Xray/rw-core.
- [x] No host nginx `stream` / `ssl_preread` layer in front of public TCP/443.
- [x] nginx fallback remains on `/dev/shm/nginx.sock` with the established PROXY-protocol design.
- [x] Telemt disabled in NEXT because of the historical public-443 conflict.

## Transport profiles

- [x] XHTTP + REALITY generated and covered by CI/live work.
- [x] RAW + REALITY generated and covered by CI/live work.
- [x] Hysteria2 + TLS generated and covered by CI/live work.
- [x] XHTTP + Hysteria2 combined generated and covered by CI.
- [x] Generated profiles validated with Xray/rw-core before atomic install.
- [x] Hysteria cert-bind recovery gated by local `hysteria|combined` transport marker.
- [x] XHTTP signature remains opt-in.

## SelfSteal / STREAM

- [x] Local-only browser runtime design.
- [x] Exactly six production audio channels.
- [x] Per-node salted browser-visible audio/catalog/history paths.
- [x] Production audio SHA256 pins.
- [x] 8 MiB per-file source-download cap.
- [x] Webroot guard rejects unsafe root path.
- [x] Failed publication preserves the prior webroot.
- [x] Pre-delta USA2 page/audio live test completed.
- [ ] Separate post-delta USA2 browser playback was not independently re-run from the GitHub automation environment; final salted behavior is covered by CI and this limitation is documented explicitly.

## RKN

- [x] Dedicated scanner chain only.
- [x] DROP scope limited to tcp/80, tcp/443 and udp/443 for the scanner set.
- [x] SSH and panel IPv4 safe-allow handling.
- [x] 120-second activation rollback.
- [x] Boot restore and randomized daily update after permanent confirmation.
- [x] List sanity checks and last-good rollback.
- [x] Update lease/stale-lock handling.
- [x] Live canary RKN permanent mode PASS.
- [x] `[Y/n]` parser hardened after canary and behavior self-tested.

## Installer / lifecycle

- [x] Immutable July source and checksum.
- [x] Immutable runtime module commit and SHA256 pins.
- [x] APP_DIR-scoped nonblocking NEXT lock.
- [x] Legacy global `remnanode` bypass removed.
- [x] Nested July menu returns clearly to REMNANODE NEXT.
- [x] Old-node installation/upgrade canary PASS.
- [x] Real client connected and carried traffic after canary upgrade.
- [x] Final live postcheck PASS.

## Review and CI

- [x] Independent external review returned MERGE: YES with no BLOCKER/HIGH at the reviewed checkpoint.
- [x] Final hardening delta covered by CI.
- [x] All six production workflows green on exact final PR head `05277579a829a977e2db103d95779f0c4d1a4b4c`.
- [x] PR #2 merged into `custom`.
- [x] All six production workflows green again on exact merge commit `e8fb95d2b9df06bb96625850409cd922606b055d`.
- [x] Live canary acceptance recorded in `CANARY_ACCEPTANCE_2026-09-09.md`.

## Freeze

- Production code merge/freeze: `e8fb95d2b9df06bb96625850409cd922606b055d`
- Runtime module commit: `5e54fd49e7b8500fe337f5df442bfa568075a147`
- July base: `34aeaa99aa1a5c21fc4f9d0c976d38607d025353`

## Next phase

AINOC fleet integration is a separate phase. Installer work is accepted and frozen before that phase begins.
