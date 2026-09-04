# Ryven — agent operating rules

Bootc image repo: three images (`ryven`, `ryven-wl`, `ryven-sericea`) built
from `Containerfile`, `Containerfile.wl`, `Containerfile.sericea` via one
unified matrix workflow (`.github/workflows/build.yml`).

## Compose layout

- `build_files/compose.sh` — shared core. Owns: log discipline (`say`, quiet
  `_q`), `retry`, repo helpers (`bootstrap_terra`, `bootstrap_fusion`,
  `lockdown_base_repos`), the NEVRA ladder (`install_priority`,
  `install_any`, `vendor_repo_install`, `copr_install_isolated`), kernel swap
  (`swap_kernel_cachyos`), NVIDIA (`install_nvidia_terra`), BetterBird/Zen,
  proton float, oo7, wl-clip-persist, final upgrade, smoke helpers.
- `build_files/build.sh`, `build-wl.sh`, `build-sericea.sh` — thin image
  scripts. They `source /ctx/compose.sh` and contain only image-specific
  package calls. **Never duplicate a helper into an image script.**
- Third-party `.repo` files stay on disk but `enabled=0` at rest
  (`lockdown_base_repos`); compose re-enables per-transaction.

## Standing product rules (do not regress)

1. **Everything tracks latest.** Bases are ublue `:latest`; weekly CI +
   `final_upgrade` float the rest. No digest pins, no version pins, no
   release-ver pinning, no "invariant" checks that assert a version.
2. **Package ladder per NEVRA** (never one mixed-repo transaction):
   official vendor/dev repos → Terra (+ `terra-nvidia` for the NVIDIA
   driver stack) → RPMFusion → official Fedora → cargo/npm/mise/bun source
   builds → Flatpak only when absolutely forced.
3. **COPR is last-resort**, one package set per `copr_install_isolated`
   call, repo file removed afterwards. These COPRs are BANNED outright:
   `bieszczaders/kernel-cachyos-addons`, `sneexy/zen-browser`,
   `brycensranch/gpu-screen-recorder`, `jdxcode/mise`,
   `vdanielmo/git-credential-manager`.
4. Kernel stays CachyOS LTO (`kernel-cachyos-lto` + devel-matched).
   NVIDIA stays the Terra-nvidia subrepo stack + `akmod-nvidia` kmod built
   for the CachyOS kernel at compose time. No CUDA toolkit. No
   `terra-release-nvidia`. No mesa-freeworld swap. No kernel versionlock.
5. Smoke checks assert **presence/behavior**, never versions. Keep the set
   lean (~15–45 per image); every check must guard a real past failure.
6. Image scripts stay thin. Shared logic goes in `compose.sh` behind a
   function with `say` logging and fail-closed errors.
7. Quiet logs: routine dnf/config output through `_q`; one `say` line per
   package set.

## CI

- `build` (matrix, `fail-fast: false`) is the only image workflow;
  `build-disk.yml` (ISO/qcow2) triggers off it; `lint.yml` runs
  ShellCheck + Hadolint on every push/PR.
- Validate locally before pushing: `bash -n` + `shellcheck --severity=error
  -x` every touched shell file, `python3 -c 'import yaml,...'` any touched
  workflow, `just check` for the Justfile.
- Push direct to `main` in large batches. Never touch auth (`gh auth
  login` is the owner's personal flow).
