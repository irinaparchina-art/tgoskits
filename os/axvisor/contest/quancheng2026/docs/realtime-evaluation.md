# Task-One Realtime Evaluation

This note turns the redcola realtime evidence into a reviewer-facing comparison
for the Quancheng Lab 2026 AxVisor task. It separates the native RTOS primitive
baseline from the AxVisor-hosted dual-guest periodic-task evidence, because the
two tests measure different layers of the stack.

## Measurement Scope

The native RTOS baseline uses Zephyr's `tests/benchmarks/latency_measure` on
native QEMU `qemu_cortex_a53`. It measures Zephyr kernel primitives and ISR
resume paths without AxVisor or a Linux guest.

The AxVisor evidence runs the required mixed system topology:

```text
Linux guest, 2 vCPU, pCPU 1-2  <--- IP/UDP --->  Zephyr RTOS guest, 1 vCPU, pCPU 0
```

The Linux guest periodic probe runs a static AArch64 test program that uses
`CLOCK_MONOTONIC` and `clock_nanosleep(..., TIMER_ABSTIME, ...)` with a 1 ms
period. The RTOS guest periodic probe runs inside the Zephyr guest and measures
the overrun of a 1 ms `k_busy_wait` loop. The integrated AxVisor script also
requires plain UDP, QCZ1 reliable UDP, AI control, tcpdump and final guest
markers to pass in the same run.

## Native Zephyr Baseline

| Metric | Result |
|---|---:|
| Board | `qemu_cortex_a53` |
| Benchmark | `tests/benchmarks/latency_measure` |
| Reported metrics | `47` |
| Preemptive `k_yield` context switch | `2400 ns` |
| Cooperative `k_yield` context switch | `2400 ns` |
| ISR return to interrupted thread | `1071 ns` |
| ISR return and switch to another thread | `1359 ns` |
| Semaphore take blocking switch | `3440 ns` |
| Semaphore give wake switch | `3967 ns` |
| Maximum reported primitive latency | `46703 ns` |
| Result marker | `PROJECT EXECUTION SUCCESSFUL` |

This baseline proves that the selected Zephyr board and benchmark environment
are healthy. It is not used as a direct numeric replacement for the AxVisor
periodic-task results because the AxVisor runs include VM exits, virtual
interrupt delivery, virtual/physical timer handling, Linux guest load and
cross-guest network traffic.

## AxVisor Long-Sample Comparison

All rows below use the same dual-guest script, same IP/UDP topology, same 1 ms
periodic probes and the same QCZ1/AI application path. The only workload knob is
the number of busy-loop workers started inside the 2-vCPU Linux guest.

| Scenario | Linux workers | Linux samples | Linux mean/p99/max ns | RTOS samples | RTOS mean/p99/max ns | UDP | QCZ1 | AI e2e mean/max us | Drops | Evidence SHA256 |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|
| No Linux pressure | `0` | `10000` | `859358 / 2788848 / 12764288` | `1000` | `87811 / 613216 / 5328816` | `20/20` | `10/10` | `1668 / 1925` | `0` | `b3a6dcc0503f7d2fae4add93c05c20aaad0a33874ac924bf1b9b26b9a7295ddd` |
| One Linux worker | `1` | `10000` | `827911 / 2559424 / 9586112` | `1000` | `122604 / 1227840 / 4352208` | `20/20` | `10/10` | `1996 / 5333` | `0` | `d4300613f3835c71f029e656d7dd209b84fbac25333a0d8378e7f3b72db29d0b` |
| Two Linux workers | `2` | `10000` | `894770 / 4346944 / 9145360` | `1000` | `98703 / 726688 / 3676896` | `20/20` | `10/10` | `4964 / 21059` | `0` | `69adb1c9741b33b4a5f718096f5e26c457ddbc450fa96168c15aa5dd86599cfa` |
| Four Linux workers | `4` | `10000` | `2966298 / 41868000 / 52850464` | `1000` | `80229 / 1255504 / 6179136` | `20/20` | `10/10` | `8140 / 39642` | `0` | `9d8d94ac85222f73fa4fb5249cbc94ca52a1b0cb2c656c5d8105069da4bcb12f` |

Key observations:

- The Linux guest 1 ms periodic probe remains in the same sub-millisecond mean
  lateness band across 0, 1 and 2 Linux worker configurations.
- The 4-worker run intentionally overcommits the 2-vCPU Linux guest. It raises
  Linux-side p99/max latency, but the integrated UDP/QCZ1/AI path still passes
  with no tcpdump kernel drops.
- The RTOS guest periodic probe remains below 0.13 ms mean lateness in the 0,
  1, 2 and 4 worker long-sample configurations.
- Cross-guest plain UDP, QCZ1 reliable UDP and AI control all remain at `100%`
  success in the same runs.
- The tcpdump kernel drop counter remains `0`, so the network evidence is not
  relying on hidden packet loss recovery outside the application protocol.
- The 2-worker and 4-worker runs are intentionally harsh for a 2-vCPU Linux
  guest. The AI maximum end-to-end latency increases under pressure, but the
  closed loop still completes `10/10` control transactions and the RTOS
  periodic probe remains stable.

## Two-Worker Stability Campaign

The strongest Linux-pressure configuration was rerun three times. Each round
uses the same 2-worker Linux guest load, the same dual-guest topology and the
same `analyze_dual_guest_realtime.py --fail-on-missing` gate.

| Round | Result | Linux mean/p99/max ns | RTOS mean/p99/max ns | UDP | QCZ1 | AI | AI e2e mean/max us | Drops | Evidence SHA256 |
|---:|---|---:|---:|---:|---:|---:|---:|---:|---|
| `1` | PASS | `1275322 / 16139568 / 41942128` | `103672 / 864272 / 4739680` | `20/20` | `10/10` | `10/10` | `1585 / 2230` | `0` | `fbe83e24d41cc3cc1c9172656de3212e4e044625c0837f6ba7c8ec3f941ddb26` |
| `2` | PASS | `991262 / 4300992 / 9572688` | `115154 / 933488 / 4327488` | `20/20` | `10/10` | `10/10` | `5177 / 24792` | `0` | `6437349e481dd3b5282abe27a34085e4a0d26b214cd7a88478ff7532446f7a16` |
| `3` | PASS | `1185251 / 7174032 / 23575136` | `118194 / 984736 / 4949296` | `20/20` | `10/10` | `10/10` | `2861 / 6457` | `0` | `38aac4038f06ae1731125cea46e6afce0b18d0cc5f0845ef7a562676a8cc97f5` |

Aggregate range across the three 2-worker rounds:

| Metric | Min | Mean | Max |
|---|---:|---:|---:|
| Linux periodic p99 ns | `4300992` | `9204864` | `16139568` |
| RTOS periodic p99 ns | `864272` | `927499` | `984736` |
| UDP RTT max us | `32804` | `33527` | `33907` |
| QCZ1 reliable max us | `6173` | `16129` | `26197` |
| AI end-to-end max us | `2230` | `11160` | `24792` |

## Reproducibility Gates

The first-stage contest directory includes:

- `scripts/run_native_zephyr_latency_baseline.sh`
- `scripts/run_axvisor_dual_guest_qcz1_ai.sh`
- `scripts/analyze_zephyr_latency_measure.py`
- `scripts/analyze_dual_guest_realtime.py`
- `results/realtime-comparison.csv`
- `results/stability/2026-07-27-stress2-3x/stability-summary.md`

The AxVisor integrated script returns `PASS` only when the expected Linux guest,
RTOS guest, network, QCZ1, AI, periodic-probe and tcpdump markers are present.
This makes the evidence stricter than a single latency microbenchmark: realtime
measurements are collected while the contest communication and AI-control path
are active.
