#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
contest_dir="$(cd "${script_dir}/.." && pwd)"
repo="$(cd "${script_dir}/../../../../.." && pwd)"
stamp="$(date +%Y-%m-%d_%H-%M-%S)-dual-guest-qcz1-ai"
evidence_dir="/tmp/${stamp}"
qemu_timeout_seconds=95
prepare_only=0
linux_rt_samples=2000
linux_stress_workers=0
linux_stress_seconds=0
net_mode="tap"

usage() {
    cat <<'EOF'
Usage: run_axvisor_dual_guest_qcz1_ai.sh [options]

Options:
  --repo PATH              tgoskits repository root.
  --evidence-dir PATH      Output evidence directory.
  --timeout SECONDS        AxVisor/QEMU timeout. Default: 95.
  --linux-rt-samples N     Linux guest 1 ms periodic samples. Default: 2000.
  --linux-stress-workers N Linux guest CPU busy-loop workers. Default: 0.
  --linux-stress-seconds N Linux guest stress duration, 0 means until probes finish. Default: 0.
  --net-mode MODE          Network backend: tap or hub. Default: tap.
  --prepare-only           Build rootfs/configs but do not run QEMU.
  -h, --help               Show this help.

The script reproduces the AxVisor dual-guest contest path:
Linux guest 192.0.2.10 <-> Zephyr RTOS guest 192.0.2.20 over IPv4/UDP.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --repo)
            repo="$2"
            shift 2
            ;;
        --evidence-dir)
            evidence_dir="$2"
            shift 2
            ;;
        --timeout)
            qemu_timeout_seconds="$2"
            shift 2
            ;;
        --linux-rt-samples)
            linux_rt_samples="$2"
            shift 2
            ;;
        --linux-stress-workers)
            linux_stress_workers="$2"
            shift 2
            ;;
        --linux-stress-seconds)
            linux_stress_seconds="$2"
            shift 2
            ;;
        --net-mode)
            net_mode="$2"
            shift 2
            ;;
        --prepare-only)
            prepare_only=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown argument: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

for numeric_value in "${qemu_timeout_seconds}" "${linux_rt_samples}" "${linux_stress_workers}" "${linux_stress_seconds}"; do
    if [[ ! "${numeric_value}" =~ ^[0-9]+$ ]]; then
        echo "numeric argument expected, got: ${numeric_value}" >&2
        exit 3
    fi
done
if [[ "${linux_rt_samples}" -lt 1 ]]; then
    echo "linux_rt_samples must be at least 1" >&2
    exit 3
fi
case "${net_mode}" in
    tap|hub)
        ;;
    *)
        echo "net_mode must be tap or hub, got: ${net_mode}" >&2
        exit 3
        ;;
esac

repo="$(cd "${repo}" && pwd)"
axvisor="${repo}/os/axvisor"
contest_dir="${axvisor}/contest/quancheng2026"
rootfs_cache="${repo}/tmp/axbuild/rootfs"
rootfs_archive="${rootfs_cache}/rootfs-aarch64-alpine.img.tar.xz"
expected_archive_sha256="d97245a69c60f7a0b6f9d510259f79d873e3fe6277264c936c0b26418d1c3f19"
linux_kernel="${axvisor}/tmp/images/qemu-aarch64/linux/linux-qemu"
zephyr_bin="${axvisor}/tmp/images/qemu-aarch64/zephyr-e1000-0x90000000-qcz1/zephyr.bin"
host_dtb="${axvisor}/tmp/configs/2026-07-24_qemu-aarch64-host-reserve-zephyr-0x90000000.dtb"
build_dir="${repo}/tmp/quancheng2026-dual-guest-qcz1-ai-build"
rootfs_dir="${rootfs_cache}/quancheng2026-dual-guest-qcz1-ai"
rootfs_img="${rootfs_dir}/rootfs-aarch64-alpine.img"
config_dir="${build_dir}/configs"
binary_dir="${build_dir}/bin"
init_normalized="${build_dir}/qc-dual-net.sh"
echo_probe_src="${contest_dir}/linux/qc_dual_guest_udp_echo_probe.c"
qcz1_demo_src="${contest_dir}/linux/qc_qcz1_guest_demo.c"
rt_probe_src="${contest_dir}/linux/qc_periodic_latency_probe.c"
init_src="${contest_dir}/linux/qc_dual_guest_qcz1_ai_init.sh"
echo_probe_obj="${binary_dir}/qc-udp-probe.o"
echo_probe_bin="${binary_dir}/qc-udp-probe"
qcz1_demo_obj="${binary_dir}/qc-qcz1-demo.o"
qcz1_demo_bin="${binary_dir}/qc-qcz1-demo"
rt_probe_obj="${binary_dir}/qc-rt-probe.o"
rt_probe_bin="${binary_dir}/qc-rt-probe"
lld="${HOME}/.rustup/toolchains/stable-x86_64-unknown-linux-gnu/lib/rustlib/x86_64-unknown-linux-gnu/bin/gcc-ld/ld.lld"

run_fsck() {
    local image="$1"
    local log="$2"
    set +e
    e2fsck -fy "${image}" >"${log}" 2>&1
    local status=$?
    set -e
    tail -12 "${log}"
    if [[ "${status}" -ne 0 && "${status}" -ne 1 ]]; then
        echo "e2fsck failed with status ${status}" >&2
        exit "${status}"
    fi
}

sudo_cmd() {
    sudo "$@"
}

compile_static_aarch64() {
    local src="$1"
    local obj="$2"
    local bin="$3"
    shift 3

    clang \
        --target=aarch64-linux-gnu \
        -c \
        -nostdlib \
        -ffreestanding \
        -fno-builtin \
        -fno-stack-protector \
        -fno-unwind-tables \
        -fno-asynchronous-unwind-tables \
        -Oz \
        -Wall \
        -Wextra \
        "$@" \
        -o "${obj}" \
        "${src}"

    "${lld}" \
        -m aarch64elf \
        -static \
        -e _start \
        --build-id=none \
        -z noexecstack \
        -o "${bin}" \
        "${obj}"

    readelf -h "${bin}" | grep -Eq "Machine:.*AArch64"
    readelf -h "${bin}" | grep -Eq "Type:.*EXEC"
}

mkdir -p "${evidence_dir}" "${build_dir}" "${config_dir}" "${binary_dir}" "${rootfs_dir}"

exec > >(tee "${evidence_dir}/runner.log") 2>&1

echo "experiment=AxVisor dual guest QCZ1 AI"
echo "repo=${repo}"
echo "axvisor=${axvisor}"
echo "contest_dir=${contest_dir}"
echo "evidence_dir=${evidence_dir}"
echo "linux_rt_samples=${linux_rt_samples}"
echo "linux_stress_workers=${linux_stress_workers}"
echo "linux_stress_seconds=${linux_stress_seconds}"
echo "net_mode=${net_mode}"

for required in \
    clang \
    readelf \
    debugfs \
    e2fsck \
    tar \
    timeout \
    cargo
do
    if ! command -v "${required}" >/dev/null 2>&1; then
        echo "missing_required_tool=${required}" >&2
        exit 10
    fi
done

if [[ ! -x "${lld}" ]]; then
    lld="$(command -v ld.lld || true)"
fi
if [[ -z "${lld}" || ! -x "${lld}" ]]; then
    echo "missing_required_tool=ld.lld" >&2
    exit 11
fi

for required_path in \
    "${rootfs_archive}" \
    "${linux_kernel}" \
    "${zephyr_bin}" \
    "${host_dtb}" \
    "${echo_probe_src}" \
    "${qcz1_demo_src}" \
    "${rt_probe_src}" \
    "${init_src}"
do
    if [[ ! -f "${required_path}" ]]; then
        echo "missing_required_path=${required_path}" >&2
        exit 12
    fi
done

archive_sha256="$(sha256sum "${rootfs_archive}" | awk '{print $1}')"
echo "rootfs_archive_sha256=${archive_sha256}"
if [[ "${archive_sha256}" != "${expected_archive_sha256}" ]]; then
    echo "rootfs archive checksum mismatch" >&2
    exit 13
fi

{
    IFS= read -r first_line || true
    printf '%s\n' "${first_line%$'\r'}"
    printf 'QC_LINUX_STRESS_WORKERS=%s\n' "${linux_stress_workers}"
    printf 'QC_LINUX_STRESS_SECONDS=%s\n' "${linux_stress_seconds}"
    while IFS= read -r line || [[ -n "${line}" ]]; do
        printf '%s\n' "${line%$'\r'}"
    done
} <"${init_src}" >"${init_normalized}"
chmod 0755 "${init_normalized}"

compile_static_aarch64 "${echo_probe_src}" "${echo_probe_obj}" "${echo_probe_bin}"
compile_static_aarch64 "${qcz1_demo_src}" "${qcz1_demo_obj}" "${qcz1_demo_bin}"
compile_static_aarch64 "${rt_probe_src}" "${rt_probe_obj}" "${rt_probe_bin}" "-DQC_SAMPLES=${linux_rt_samples}"

echo "--- static binaries ---"
file "${echo_probe_bin}" "${qcz1_demo_bin}" "${rt_probe_bin}"
sha256sum \
    "${echo_probe_src}" "${echo_probe_bin}" \
    "${qcz1_demo_src}" "${qcz1_demo_bin}" \
    "${rt_probe_src}" "${rt_probe_bin}" \
    "${init_normalized}" \
    | tee "${evidence_dir}/artifact-sha256.txt"

rm -f "${rootfs_img}"
tar -xJf "${rootfs_archive}" -C "${rootfs_dir}"
if [[ ! -f "${rootfs_img}" ]]; then
    echo "rootfs extraction did not create ${rootfs_img}" >&2
    exit 14
fi

echo "--- fsck before injection ---"
run_fsck "${rootfs_img}" "${evidence_dir}/rootfs-fsck-before.log"

debugfs_cmd="${build_dir}/inject-rootfs.debugfs"
cat >"${debugfs_cmd}" <<EOF
rm /qc-dual-net.sh
rm /qc-udp-probe
rm /qc-qcz1-demo
rm /qc-rt-probe
write ${init_normalized} /qc-dual-net.sh
set_inode_field /qc-dual-net.sh mode 0100755
write ${echo_probe_bin} /qc-udp-probe
set_inode_field /qc-udp-probe mode 0100755
write ${qcz1_demo_bin} /qc-qcz1-demo
set_inode_field /qc-qcz1-demo mode 0100755
write ${rt_probe_bin} /qc-rt-probe
set_inode_field /qc-rt-probe mode 0100755
stat /qc-dual-net.sh
stat /qc-udp-probe
stat /qc-qcz1-demo
stat /qc-rt-probe
EOF

debugfs -w -f "${debugfs_cmd}" "${rootfs_img}" | tee "${evidence_dir}/rootfs-debugfs-inject.log"

debugfs -R "dump /qc-dual-net.sh ${build_dir}/dump-qc-dual-net.sh" "${rootfs_img}" >/dev/null 2>&1
debugfs -R "dump /qc-udp-probe ${build_dir}/dump-qc-udp-probe" "${rootfs_img}" >/dev/null 2>&1
debugfs -R "dump /qc-qcz1-demo ${build_dir}/dump-qcz1-demo" "${rootfs_img}" >/dev/null 2>&1
debugfs -R "dump /qc-rt-probe ${build_dir}/dump-qc-rt-probe" "${rootfs_img}" >/dev/null 2>&1
cmp "${init_normalized}" "${build_dir}/dump-qc-dual-net.sh"
cmp "${echo_probe_bin}" "${build_dir}/dump-qc-udp-probe"
cmp "${qcz1_demo_bin}" "${build_dir}/dump-qcz1-demo"
cmp "${rt_probe_bin}" "${build_dir}/dump-qc-rt-probe"

echo "--- fsck after injection ---"
run_fsck "${rootfs_img}" "${evidence_dir}/rootfs-fsck-after.log"
sha256sum "${rootfs_img}" | tee "${evidence_dir}/rootfs-sha256.txt"

cat >"${config_dir}/qemu-aarch64.toml" <<'EOF'
features = [
    "ax-driver/virtio-blk",
    "fs",
]
log = "Info"
target = "aarch64-unknown-none-softfloat"
vm_configs = []
EOF

if [[ "${net_mode}" == "tap" ]]; then
    net_linux_backend="tap,id=net_linux,ifname=tap-qc-linux,script=no,downscript=no"
    net_rtos_backend="tap,id=net_rtos_e1000,ifname=tap-qc-rtos,script=no,downscript=no"
else
    net_linux_backend="hubport,id=net_linux,hubid=42"
    net_rtos_backend="hubport,id=net_rtos_e1000,hubid=42"
fi

cat >"${config_dir}/runtime.toml" <<EOF
args = [
  "-nographic",
  "-monitor",
  "unix:${evidence_dir}/monitor.sock,server=on,wait=off",
  "-global",
  "virtio-mmio.force-legacy=false",
  "-cpu",
  "cortex-a72",
  "-machine",
  "virt,virtualization=on,gic-version=3",
  "-dtb",
  "${host_dtb}",
  "-smp",
  "4",
  "-device",
  "virtio-blk-device,drive=disk0,bus=virtio-mmio-bus.15",
  "-drive",
  "id=disk0,if=none,format=raw,file=${rootfs_img}",
  "-append",
  "root=/dev/vda rw init=/qc-dual-net.sh noirqdebug",
  "-m",
  "2g",
  "-netdev",
  "${net_linux_backend}",
  "-device",
  "virtio-net-device,netdev=net_linux,mac=52:54:00:12:34:10,bus=virtio-mmio-bus.31,csum=off,gso=off,ctrl_guest_offloads=off,guest_csum=off,guest_tso4=off,guest_tso6=off,guest_ecn=off,guest_ufo=off,guest_uso4=off,guest_uso6=off,host_tso4=off,host_tso6=off,host_ecn=off,host_ufo=off,host_uso=off,mrg_rxbuf=off",
  "-netdev",
  "${net_rtos_backend}",
  "-device",
  "e1000,netdev=net_rtos_e1000,mac=52:54:00:12:34:20,addr=0x1",
]
fail_regex = ["panicked at", "ZEPHYR FATAL ERROR", "Kernel panic"]
success_regex = ["QC_DUAL_GUEST_LINUX_INIT=PASS"]
to_bin = true
uefi = false
EOF

cat >"${config_dir}/zephyr-e1000-qcz1-vm.toml" <<EOF
[base]
id = 1
name = "zephyr-e1000-0x900-qcz1-pcpu0-root"
vm_type = 1
cpu_num = 1
phys_cpu_ids = [0]

[kernel]
entry_point = 0x9000_117c
image_location = "memory"
kernel_path = "${zephyr_bin}"
kernel_load_addr = 0x9000_0000

memory_regions = [
  [0x9000_0000, 0x0800_0000, 0x7, 2],
]

[devices]
interrupt_mode = "passthrough"
emu_devices = []
passthrough_devices = [
  ["/"],
]
passthrough_irqs = [4]
passthrough_addresses = []
excluded_devices = []
EOF

cat >"${config_dir}/linux-smp2-gppt-gicd-vm.toml" <<EOF
[base]
id = 2
name = "linux-qemu-pcpu1-2-gppt-gicd"
vm_type = 1
cpu_num = 2
phys_cpu_ids = [1, 2]

[kernel]
entry_point = 0x8020_0000
image_location = "memory"
kernel_path = "${linux_kernel}"
kernel_load_addr = 0x8020_0000
dtb_load_addr = 0x8000_0000

memory_regions = [
  [0x8000_0000, 0x1000_0000, 0x7, 1],
]

[devices]
interrupt_mode = "passthrough"
emu_devices = [
  ["gppt-gicd", 0x0800_0000, 0x1_0000, 0, 0x21, []],
]
passthrough_devices = [
  ["/intc@8000000"],
  ["/timer"],
  ["/psci"],
  ["/chosen"],
  ["/pl011@9000000"],
  ["/virtio_mmio@a003e00"],
  ["/virtio_mmio@a001e00"],
]
passthrough_irqs = [1, 31, 47]
passthrough_addresses = []
excluded_devices = []
EOF

cp "${config_dir}"/*.toml "${evidence_dir}/"

echo "rootfs_image=${rootfs_img}"
echo "config_dir=${config_dir}"

if [[ "${prepare_only}" -eq 1 ]]; then
    echo "result=PREPARE_ONLY"
    exit 0
fi

if pgrep -af qemu-system >"${evidence_dir}/preexisting-qemu.txt"; then
    echo "preexisting_qemu=YES"
    cat "${evidence_dir}/preexisting-qemu.txt"
    exit 20
fi

tcpdump_pid=""
if [[ "${net_mode}" == "tap" ]]; then
    if ! sudo -v; then
        echo "sudo authentication failed; run sudo -v before invoking this script or run from an authenticated terminal." >&2
        exit 21
    fi

    for dev in tap-qc-linux tap-qc-rtos br-qc-dual; do
        sudo_cmd ip link set "${dev}" down >/dev/null 2>&1 || true
    done
    sudo_cmd ip link delete tap-qc-linux >/dev/null 2>&1 || true
    sudo_cmd ip link delete tap-qc-rtos >/dev/null 2>&1 || true
    sudo_cmd ip link delete br-qc-dual type bridge >/dev/null 2>&1 || true
    sudo_cmd ip link add br-qc-dual type bridge >/dev/null
    sudo_cmd ip tuntap add dev tap-qc-linux mode tap user "$(id -un)" >/dev/null
    sudo_cmd ip tuntap add dev tap-qc-rtos mode tap user "$(id -un)" >/dev/null
    sudo_cmd ip link set tap-qc-linux master br-qc-dual >/dev/null
    sudo_cmd ip link set tap-qc-rtos master br-qc-dual >/dev/null
    sudo_cmd ip link set br-qc-dual up >/dev/null
    sudo_cmd ip link set tap-qc-linux up >/dev/null
    sudo_cmd ip link set tap-qc-rtos up >/dev/null

    {
        echo "net_mode=tap"
        ip -br link show dev br-qc-dual || true
        ip -br link show dev tap-qc-linux || true
        ip -br link show dev tap-qc-rtos || true
    } | tee "${evidence_dir}/bridge.txt"

    if command -v tcpdump >/dev/null 2>&1; then
        sudo_cmd timeout --signal=INT --kill-after=2s "$((qemu_timeout_seconds + 5))" \
            tcpdump -eni br-qc-dual -vv udp port 4242 \
            >"${evidence_dir}/tcpdump.log" 2>&1 &
        tcpdump_pid=$!
    fi
else
    {
        echo "net_mode=hub"
        echo "qemu_netdev=hubport,hubid=42"
        echo "bridge=SKIPPED"
        echo "tcpdump=SKIPPED"
    } | tee "${evidence_dir}/bridge.txt"
fi

set +e
(
    cd "${axvisor}"
    timeout --signal=INT --kill-after=10s "${qemu_timeout_seconds}" cargo xtask qemu \
        --config "${config_dir}/qemu-aarch64.toml" \
        --qemu-config "${config_dir}/runtime.toml" \
        --vmconfigs "${config_dir}/zephyr-e1000-qcz1-vm.toml" \
        --vmconfigs "${config_dir}/linux-smp2-gppt-gicd-vm.toml" \
        --rootfs "${rootfs_img}"
) >"${evidence_dir}/qemu.log" 2>&1
qemu_status=$?
set -e

sleep 2
if [[ -n "${tcpdump_pid}" ]] && kill -0 "${tcpdump_pid}" >/dev/null 2>&1; then
    sudo_cmd kill -INT "${tcpdump_pid}" >/dev/null 2>&1 || true
    wait "${tcpdump_pid}" >/dev/null 2>&1 || true
fi

{
    echo "qemu_status=${qemu_status}"
    echo "net_mode=${net_mode}"
    echo "--- qc markers ---"
    grep -aE 'QC_|Received and replied|Created VM|Boot hart|Failed to assign|panic|ERROR|WARN' "${evidence_dir}/qemu.log" \
        | grep -av 'QC_SYNC_DIAG' \
        | tail -260 || true
    echo "--- tcpdump tail ---"
    if [[ -f "${evidence_dir}/tcpdump.log" ]]; then
        tail -100 "${evidence_dir}/tcpdump.log"
    else
        echo "tcpdump=SKIPPED"
    fi
} | tee "${evidence_dir}/summary.txt"

required_markers=(
    "QC_RT_PERIODIC_RESULT=PASS"
    "QC_RTOS_PERIODIC_RESULT=PASS"
    "QC_DUAL_GUEST_UDP_ECHO_RESULT=PASS"
    "QC_QCZ1_RELIABLE_RESULT=PASS"
    "QC_AI_CONTROL_RESULT=PASS"
    "QC_QCZ1_GUEST_DEMO=PASS"
    "QC_DUAL_GUEST_LINUX_INIT=PASS"
)

missing=0
for marker in "${required_markers[@]}"; do
    if ! grep -aq "${marker}" "${evidence_dir}/qemu.log"; then
        echo "missing_marker=${marker}"
        missing=1
    fi
done

if [[ "${qemu_status}" -eq 0 && "${missing}" -eq 0 ]]; then
    echo "result=PASS"
    echo "evidence_dir=${evidence_dir}"
    exit 0
fi

echo "result=FAIL"
echo "evidence_dir=${evidence_dir}"
exit 1
