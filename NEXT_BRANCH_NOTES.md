# REMNANODE NEXT — production status

This document replaces the old pre-merge branch notes. PR #2 has completed review, live canary validation and production merge into `custom`.

## Final state

- Production merge commit: `e8fb95d2b9df06bb96625850409cd922606b055d`
- Pinned July base: `34aeaa99aa1a5c21fc4f9d0c976d38607d025353`
- Pinned runtime module commit: `5e54fd49e7b8500fe337f5df442bfa568075a147`
- Live old-node canary: PASS
- Real client traffic after upgrade: PASS
- Six production CI workflows on the PR head: PASS
- Six production CI workflows on the merge commit on `custom`: PASS

## Production architecture

- XHTTP + REALITY — TCP/443
- RAW + REALITY — TCP/443
- Hysteria2 + TLS — UDP/443
- XHTTP + Hysteria2 combined — TCP/443 + UDP/443
- public TCP/443 owner remains Xray/rw-core
- nginx remains behind `/dev/shm/nginx.sock` using the established PROXY-protocol fallback design
- no host nginx `stream` / `ssl_preread` layer in front of Xray
- Telemt remains disabled in NEXT because its historical host-nginx mode conflicts with the public-443 invariant

## Canary findings closed

The live old-node canary exposed two operator-facing defects and both were fixed before merge:

1. RKN `[Y/n]` confirmation now normalizes CR/whitespace/case, accepts supported yes/no forms and reprompts invalid answers instead of silently choosing `No`.
2. The nested July menu now says `0) ↩️ Назад в REMNANODE NEXT`, and its successful-install hint points to `remnanode-next` rather than the removed legacy bypass command.

## SelfSteal / STREAM

The production STREAM implementation publishes exactly six local same-origin channels. Browser-visible audio/catalog/history paths are salted per node. Production audio downloads are checksum-pinned and limited to 8 MiB per file. External browser runtime origins from the abandoned Radio Book experiment are not present.

Accepted residuals remain documented in `REVIEW_CLAUDE.md`.

## Operator entrypoint

Use `setup_node_next.sh` and then `remnanode-next`.

`setup_node.sh` remains only as the historical July implementation that NEXT consumes from an immutable commit. It is not the normal production management entrypoint.

## Evidence

- `CANARY_ACCEPTANCE_2026-09-09.md` — final live canary record
- `REVIEW_CLAUDE.md` — external-review and hardening context
- `REVIEW_CHECKLIST.md` — final gate status
- `production/modules.sha256` — runtime module checksums

The next separate phase is AINOC fleet integration. No AINOC production changes are part of this installer release.
