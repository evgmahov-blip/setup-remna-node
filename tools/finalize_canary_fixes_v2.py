#!/usr/bin/env python3
import subprocess
import finalize_canary_fixes as f

BRANCH = "fix/xhttp-raw-hysteria-from-july7"

f.run("git", "config", "user.name", "github-actions[bot]")
f.run("git", "config", "user.email", "41898282+github-actions[bot]@users.noreply.github.com")

# Commit A: production modules only. Do not touch workflow files from GITHUB_TOKEN.
f.patch_rkn_manager()
f.run("bash", "-n", "production/rkn-watcher-manager.sh")
f.run("bash", "production/rkn-watcher-manager.sh", "selftest-input")
patched_rkn_sha = f.derive_patched_rkn_sha()
print("patched RKN SHA:", patched_rkn_sha)
rkn_sha, guard_sha = f.patch_runtime_guard_and_manifest(patched_rkn_sha)
f.run("bash", "-n", "production/next-runtime-guards.sh")
f.run("sha256sum", "-c", "production/modules.sha256")
f.run("git", "add", "production/rkn-watcher-manager.sh", "production/next-runtime-guards.sh", "production/modules.sha256")
f.run("git", "commit", "-m", "fix: harden RKN confirmation after live canary")
f.run("git", "push", "origin", f"HEAD:{BRANCH}")
module_ref = subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip()
print("immutable module ref:", module_ref)

# Commit B: wrapper pins immutable commit A and fixes nested July UX.
f.patch_wrapper(module_ref, rkn_sha, guard_sha)
f.run("bash", "-n", "setup_node_next.sh")
f.verify_wrapper_against_legacy()
f.run("git", "add", "setup_node_next.sh")
f.run("git", "commit", "-m", "fix: clarify nested NEXT return and repin modules")
f.run("git", "push", "origin", f"HEAD:{BRANCH}")
print("FINAL_HEAD", subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip())
