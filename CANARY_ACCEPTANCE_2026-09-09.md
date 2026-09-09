# REMNANODE NEXT — live canary acceptance (2026-09-09)

This file records the final old-node canary performed before merging PR #2 into `custom`.

## Result

**PASS.** A previously installed, non-critical Remnawave node was upgraded through `remnanode-next` using the pinned July baseline plus NEXT post-processing. After the upgrade a real client connected successfully and carried traffic.

Final live checks confirmed:

- `remnanode` container running;
- `remnawave-nginx` container running;
- public TCP/443 owned by `rw-core`;
- no host nginx listener on public TCP/443;
- SelfSteal nginx Unix socket `/dev/shm/nginx.sock` present;
- SelfSteal webroot present;
- node certificate and private key present;
- node metadata (`.node_domain`, `.panel_ip`, `.protocol`) present;
- RKN scanner guard active and attached to INPUT;
- RKN boot restore enabled;
- RKN daily update timer enabled;
- RKN rollback timer absent after permanent confirmation;
- `remnanode-next` installed;
- legacy global `remnanode` command removed.

## Canary findings fixed before merge

### 1. RKN permanent confirmation

The live canary exposed a fragile `[Y/n]` parser: an entered affirmative answer could fall through to the safe `No` branch when the input contained formatting/terminal artifacts.

The production RKN manager now normalizes CR/whitespace and accepted yes/no forms, rejects unknown answers, and reprompts instead of silently interpreting an unknown value as `No`. The non-interactive safety behavior remains unchanged unless `RKN_ASSUME_KEEP=1` is explicitly supplied. A behavior self-test covers empty/default, case variants, whitespace, CRLF, yes/no and invalid input.

### 2. Nested July menu wording

The embedded July management menu previously displayed `0) Выход`, even though selecting it returns control to REMNANODE NEXT. NEXT now rewrites the nested label to `0) ↩️ Назад в REMNANODE NEXT` and rewrites the successful-install command hint from the removed legacy `remnanode` command to `remnanode-next`. The adapter fails closed if those rewrites are not present.

## Immutable runtime set

- July baseline: `34aeaa99aa1a5c21fc4f9d0c976d38607d025353`
- NEXT runtime module commit: `5e54fd49e7b8500fe337f5df442bfa568075a147`
- RKN manager SHA256: `283414299df4e12e3d12b586ab71b1278968fa77c5ebf85eb61f37ee5bcf68e9`
- NEXT runtime guards SHA256: `620797d0677d091d6550894e32fea58ce7f2adf2f125d6f6ccfb217a7b3382fd`

The wrapper pins the module commit and module hashes; mutable branch content is not used for runtime modules.

## Architecture accepted

The live canary preserves the production invariant: Xray/rw-core owns public TCP/443 and nginx remains behind the Unix socket. No host nginx `stream`/`ssl_preread` layer is inserted in front of Xray. Telemt remains disabled in NEXT because its historical host-nginx mode conflicts with that invariant.

## STREAM note

The pre-delta USA2 live test confirmed the page and audio. The final salted STREAM implementation is covered by checksum/size/path CI. A separate post-delta browser playback on USA2 was not independently re-run from the GitHub automation environment, because that environment has no access to the live node/browser. This is recorded explicitly rather than being reported as a performed test.
