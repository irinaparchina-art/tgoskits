# Final Submission Checklist

This checklist tracks the remaining steps from the current redcola contest
artifact state to the final Quancheng Lab submission.

## Current Ready State

| Item | Status | Evidence |
| --- | --- | --- |
| Zephyr e1000/IP baseline | READY | `docs/e1000_axvisor.md`, `rtos/zephyr_ipv4only_udp_mgmt12288.conf` |
| Linux/RTOS QCZ1 reliable UDP | READY | `docs/protocol.md`, `linux/qc_reliable_udp_client.py`, integrated run summaries |
| AI control closed loop | READY | `docs/ai-control-evaluation.md`, `linux/qc_ai_control_demo.py` |
| Realtime comparison | READY | `docs/realtime-evaluation.md`, `results/realtime-comparison.csv` |
| Stability summary | READY | `results/stability/2026-07-27-stress2-3x/stability-summary.md` |
| Reviewer scorecard | READY | `docs/scorecard-traceability.md` |
| Core patch review | READY | `docs/core-patch-review.md` |
| Demo video script | READY | `docs/demo-video-script.md` |
| PR description draft | READY | `docs/pr-description.md` |

## Before First Commit

Run from `/home/kali/qc-tgoskits`:

```bash
cd os/axvisor/contest/quancheng2026
find . -type d -name __pycache__ -prune -exec rm -rf {} +
cache_dir=/tmp/qc_pycompile_cache_$$
PYTHONPYCACHEPREFIX=$cache_dir python3 -m py_compile scripts/*.py linux/*.py
rm -rf $cache_dir
bash -n scripts/*.sh linux/*.sh
find . \( -name '*.img' -o -name '*.qcow2' -o -name '*.iso' -o -name '*.elf' -o -name '*.o' -o -name '*.bin' -o -name '__pycache__' -o -name '*.pyc' -o -name '*.log' -o -name '*.tar.gz' \) -print | sort
cd /home/kali/qc-tgoskits
git diff --check
git diff --cached --name-only | wc -l
git add --dry-run -- os/axvisor/contest/quancheng2026
```

Expected result after this checklist is added:

```text
staged before add: 0
contest dry-run path count: 38
outside contest dry-run path count: 0
```

## First Commit

Only after user authorization:

```bash
git add -- os/axvisor/contest/quancheng2026
git diff --cached --stat
git diff --cached --name-status
git commit -m "contest: add quancheng2026 AxVisor validation artifacts"
```

Do not push in this step unless separately authorized.

## Follow-Up Core Commit Order

1. `core-01-vmconfig-vtimer.patch`
2. `core-02-gic-eoi-mode.patch`
3. `core-03-bounded-diagnostics.patch` only if still needed for review/debug.
4. `core-04-axbuild-image-helper.patch` as infrastructure polish.

The review reasoning, SHA256 values and validation commands are in
`docs/core-patch-review.md`.

## Demo Video

Record the final video with `docs/demo-video-script.md`.

Capture these markers:

```text
result=PASS
plain_udp=20/20
qcz1=10/10
ai_control=10/10
QC_RTOS_PERIODIC_RESULT=PASS
QC_DUAL_GUEST_LINUX_INIT=PASS
tcpdump kernel drops=0
```

## Final Platform Submission

Submit or link:

- PR branch and commit hash.
- `docs/design.md`.
- `docs/test-report.md`.
- `docs/reproduce.md`.
- `docs/scorecard-traceability.md`.
- Demo video.
- Latest source/documentation package SHA256.

