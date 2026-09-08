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
- CI for shell syntax and generated JSON

## Not allowed in this branch

- nginx stream/ssl_preread in front of public TCP/443
- automatic rotation of a working REALITY SNI
- automatic application of RKN Watcher firewall policy during normal node installation
- merging to `custom` before live validation

See `REVIEW_CLAUDE.md` for the external review checklist.
