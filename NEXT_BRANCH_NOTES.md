# Next branch scope

This branch is intentionally based on the known-working July 7 state and keeps its dataplane architecture.

## Added

- `setup_node_next.sh` — unified color-coded menu
- `production/remnawave-transport-manager.sh`
  - XHTTP + REALITY
  - RAW + REALITY
  - Hysteria2 + TLS
  - local SelfSteal REALITY mode
  - optional external validated SNI mode
  - generated Remnawave Config Profiles and Host hints
- `production/rkn-watcher-manager.sh`
  - pinned and checksum-verified Balbuto/RKN-Watcher integration
- CI for shell syntax, pinned module checksums, runtime Xray validation and generated profiles

## Claude round-2 review fixes

Applied before live testing:

- XHTTP REALITY server mode changed to `auto` so default REALITY clients using `stream-one` are accepted.
- Hysteria2 checks that certs are visible inside `remnanode`; adding a missing cert bind requires explicit confirmation and recreates only `remnanode`.
- SelfSteal REALITY refuses nginx Unix-socket configs that do not actually listen with `ssl proxy_protocol`.
- New root modules are fetched from an immutable commit and verified by embedded SHA256 values.
- SNI pool parsing is mawk-compatible and SNI validation checks TLS 1.3, h2, certificate chain and hostname match.
- Generated profiles are runtime-tested by rw-core/Xray before atomic rename; a failed candidate does not replace the previous profile.
- XHTTP signature is preserved on regeneration, is reversible, and is opt-in for the first live test.
- RKN Watcher precheck handles non-SSH consoles fail-safe and only treats `whitelist.ips` as IP/CIDR allow entries.

## Still requires live validation

- Remnawave must be verified to transport XHTTP `extra` to clients byte-for-byte before enabling the optional signature in production.
- REALITY `minClientVer` policy must be chosen against the actual client fleet; the generator currently leaves Xray's default unless explicitly overridden.
- First live-test order: RAW + REALITY SelfSteal -> XHTTP without signature -> XHTTP with signature -> Hysteria2 last.
- Do not merge into `custom` until the controlled live test has passed.

## Not allowed in this branch

- nginx stream/ssl_preread in front of public TCP/443
- automatic rotation of a working REALITY SNI
- automatic application of RKN Watcher firewall policy during normal node installation
- merging to `custom` before live validation

See `REVIEW_CLAUDE.md` for the external review checklist.
