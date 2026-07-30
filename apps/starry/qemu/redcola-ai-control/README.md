# Redcola StarryOS AI Control Demo

This case runs a small deterministic AI-control workload as a Linux-user-mode
program inside the StarryOS QEMU guest. It is intended as bonus evidence for the
Quancheng Laboratory 2026 AxVisor contest, where StarryOS is preferred over a
standard Linux non-RT guest.

The guest program compares a fixed manual PWM baseline against a fixed-point
neural-network control policy over eight samples. The network is intentionally
tiny and deterministic for reproducibility: a 4-input, 4-hidden-unit ReLU MLP
computes a PWM command from demand, load, vibration, and bias features before
the simulated plant reports the tracking error. A successful run prints:

```text
REDCOLA_STARRY_AI_CONTROL_PASS samples=8 manual_abs_error=1013 ai_abs_error=0
```

## Build and Run

From the repository root:

```sh
cargo xtask starry app qemu -t qemu/redcola-ai-control --arch aarch64
```

The case uses `prebuild.sh` to build a static AArch64 musl binary and copy it to
the StarryOS rootfs as `/usr/bin/redcola-ai-control`. The QEMU config then runs
that binary as the shell init command and treats the PASS line as the success
marker.

## Environment Note

The StarryOS kernel build depends on the repository's normal AArch64 bare-metal
toolchain. On minimal Kali images without `aarch64-linux-musl-gcc`, the local
validation used a temporary clang-based freestanding wrapper outside the git
tree under `/tmp/redcola-toolchain/bin`, plus a tiny temporary sysroot under
`/tmp/redcola-freestanding-sysroot`. Those files are not part of this case.

Minimal Kali validation command after preparing that wrapper:

```sh
SYS=/tmp/redcola-freestanding-sysroot
RES=$(clang -print-resource-dir)
export PATH=/tmp/redcola-toolchain/bin:$PATH
export BINDGEN_EXTRA_CLANG_ARGS="-nostdinc -isystem $SYS/include -isystem $RES/include"
cargo xtask starry app qemu -t qemu/redcola-ai-control --arch aarch64
```

The wrapper must provide `aarch64-linux-musl-gcc -print-sysroot` and compile
freestanding AArch64 C sources with clang. A normal distro-provided
`aarch64-linux-musl-gcc` toolchain can be used instead.

Latest local QEMU validation:

```text
log: /home/kali/qc-evidence/starry-qemu-redcola-ai-control-mlp-20260731_025656/starry-redcola-ai-control-mlp.log
sha256: b5b16df64a76c141364b75c3c160fa5691c838d9bff3540ce226f3d02f3ea9a5
manual_abs_error=1013 ai_abs_error=0 max_ai_error=0 mean_infer_us=90
```
