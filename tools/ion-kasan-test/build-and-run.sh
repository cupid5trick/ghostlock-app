#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
build_root=${ION_KASAN_BUILD_DIR:-"${TMPDIR:-/tmp}/ghostlock-ion-kasan-${UID}"}
mkdir -p "$build_root"
run_dir=$(mktemp -d "$build_root/run.XXXXXX")
source_dir=${ION_KASAN_KERNEL_SOURCE:-"$build_root/linux-v4.14.116"}
fixed_dir="$build_root/linux-v4.14.116-fixed-src"
cross_compile=${CROSS_COMPILE:-aarch64-linux-gnu-}
cross_cc="${cross_compile}gcc"
jobs=${JOBS:-$(getconf _NPROCESSORS_ONLN)}
kernel_ref=6d1510d86ef67e5fadb8038671e2ec43416daf7f
apply_fix="$repo_root/tools/ion-kasan-test/apply-ion-fix.py"
qemu=${QEMU_SYSTEM_AARCH64:-qemu-system-aarch64}

for tool in git make python3 "$cross_cc" "$qemu" cpio gzip timeout; do
	command -v "$tool" >/dev/null || { echo "missing required tool: $tool" >&2; exit 2; }
done
if [[ ! -d "$source_dir/.git" ]]; then
	git clone --depth 1 --branch v4.14.116 https://github.com/gregkh/linux.git "$source_dir"
fi
actual_ref=$(git -C "$source_dir" rev-parse HEAD)
if [[ "$actual_ref" != "$kernel_ref" ]]; then
	echo "kernel source mismatch: expected $kernel_ref, found $actual_ref at $source_dir" >&2
	exit 2
fi
if [[ -n "$(git -C "$source_dir" status --porcelain)" ]]; then
	echo "kernel source tree has local changes: $source_dir" >&2
	exit 2
fi
if [[ -e "$fixed_dir" ]] &&
	! git -C "$source_dir" worktree list --porcelain | grep -Fqx "worktree $fixed_dir"; then
	echo "refusing to modify non-managed fixed-source path: $fixed_dir" >&2
	exit 2
fi
if [[ ! -e "$fixed_dir/.git" ]]; then
	git -C "$source_dir" worktree add --detach "$fixed_dir" "$kernel_ref"
fi
python3 "$apply_fix" "$fixed_dir"

build_kernel() {
	local label=$1
	local kernel_src=$2
	local out="$build_root/$label"
	local stage="$run_dir/$label/root"
	local module_src="$out/ion-probe-module"
	local config="$out/.config"
	mkdir -p "$out" "$stage/dev" "$module_src"
	cp "$repo_root/tools/ion-kasan-test/Makefile" \
		"$repo_root/tools/ion-kasan-test/ion_kasan_probe.c" \
		"$repo_root/tools/ion-kasan-test/ion_probe_uapi.h" "$module_src/"
	if [[ ! -f "$config" ]]; then
		make -s -C "$kernel_src" O="$out" ARCH=arm64 CROSS_COMPILE="$cross_compile" \
			HOSTCFLAGS=-fcommon defconfig
		"$kernel_src/scripts/config" --file "$config" \
			-e CONFIG_KASAN -e CONFIG_KASAN_OUTLINE -e CONFIG_SLUB \
			-e CONFIG_DEBUG_INFO -e CONFIG_STACKTRACE \
			-e CONFIG_MODULES -e CONFIG_MODULE_UNLOAD -d CONFIG_MODVERSIONS \
			-e CONFIG_DEVTMPFS -e CONFIG_DEVTMPFS_MOUNT \
			-e CONFIG_STAGING -e CONFIG_ANDROID -e CONFIG_ION -e CONFIG_ION_SYSTEM_HEAP \
			-e CONFIG_DMA_SHARED_BUFFER -e CONFIG_CMA -e CONFIG_DMA_CMA \
			-e CONFIG_IKCONFIG -e CONFIG_IKCONFIG_PROC -e CONFIG_PRINTK \
			-e CONFIG_PROC_FS -e CONFIG_SYSFS
		make -s -C "$kernel_src" O="$out" ARCH=arm64 CROSS_COMPILE="$cross_compile" \
			HOSTCFLAGS=-fcommon olddefconfig
	fi
	grep -qx 'CONFIG_KASAN=y' "$config"
	grep -qx 'CONFIG_ION=y' "$config"
	grep -qx 'CONFIG_ION_SYSTEM_HEAP=y' "$config"
	grep -qx 'CONFIG_DMA_SHARED_BUFFER=y' "$config"
	grep -qx 'CONFIG_DEVTMPFS=y' "$config"
	grep -qx 'CONFIG_MODULES=y' "$config"
	if ! make -C "$kernel_src" O="$out" ARCH=arm64 CROSS_COMPILE="$cross_compile" \
		HOSTCFLAGS=-fcommon -j"$jobs" Image >"$out/kernel-build.log" 2>&1; then
		tail -n 100 "$out/kernel-build.log" >&2
		exit 1
	fi
	if ! make -s -C "$kernel_src" O="$out" ARCH=arm64 CROSS_COMPILE="$cross_compile" \
		HOSTCFLAGS=-fcommon modules_prepare >>"$out/kernel-build.log" 2>&1; then
		tail -n 100 "$out/kernel-build.log" >&2
		exit 1
	fi
	if ! make -s -C "$kernel_src" O="$out" ARCH=arm64 CROSS_COMPILE="$cross_compile" \
		HOSTCFLAGS=-fcommon M="$module_src" KBUILD_MODPOST_WARN=1 modules \
		>>"$out/kernel-build.log" 2>&1; then
		tail -n 100 "$out/kernel-build.log" >&2
		exit 1
	fi
	install -m 0644 "$module_src/ion_kasan_probe.ko" "$stage/ion_kasan_probe.ko"
	"$cross_cc" -static -O2 -Wall -Wextra -Werror \
		"$repo_root/tools/ion-kasan-test/init.c" -o "$stage/init"
	"$cross_cc" -x c -std=gnu11 -static -O2 -Wall -Wextra -Werror \
		"$repo_root/src/core/tests/ion_backend_demo.cpp" -o "$stage/ion_backend_demo"
	chmod 0755 "$stage/init" "$stage/ion_backend_demo"
	(
		cd "$stage"
		find . -print0 | cpio --null -o --format=newc 2>/dev/null | gzip -9
	) > "$run_dir/$label-initramfs.cpio.gz"
	cp "$out/arch/arm64/boot/Image" "$run_dir/$label-Image"
	echo "$label source=$(git -C "$kernel_src" rev-parse HEAD) config=$(sha256sum "$config" | cut -d' ' -f1)"
}

run_guest() {
	local label=$1
	local log="$build_root/$label-qemu.log"
	set +e
	timeout --foreground 240 "$qemu" \
		-M virt -cpu cortex-a57 -smp 2 -m 2048 \
		-kernel "$run_dir/$label-Image" \
		-initrd "$run_dir/$label-initramfs.cpio.gz" \
		-append 'console=ttyAMA0 earlycon=pl011,0x9000000 panic=1 panic_on_oops=1 kasan_multi_shot=1' \
		-nographic -no-reboot > "$log" 2>&1
	local qemu_status=$?
	set -e
	echo "$label QEMU exit=$qemu_status log=$log"
	cat "$log"
}

build_kernel baseline "$source_dir"
build_kernel fixed "$fixed_dir"
baseline_config_hash=$(sha256sum "$build_root/baseline/.config" | cut -d' ' -f1)
fixed_config_hash=$(sha256sum "$build_root/fixed/.config" | cut -d' ' -f1)
if [[ "$baseline_config_hash" != "$fixed_config_hash" ]]; then
	echo "FAIL: baseline and fixed kernel configs differ" >&2
	echo "baseline config=$baseline_config_hash" >&2
	echo "fixed config=$fixed_config_hash" >&2
	exit 1
fi
echo "CONFIGS_MATCH sha256=$baseline_config_hash"
run_guest baseline
run_guest fixed

baseline_log="$build_root/baseline-qemu.log"
fixed_log="$build_root/fixed-qemu.log"
if ! grep -q 'ION_DRIVER_READY real_misc_device=/dev/ion' "$baseline_log" ||
	! grep -q 'KernelAddressSanitizer initialized' "$baseline_log" ||
	! grep -q 'ION_ALLOC_OK' "$baseline_log" ||
	! grep -q 'ION_SYNC_END_OK' "$baseline_log" ||
	! grep -q 'ION_PROBE_HELD' "$baseline_log"; then
	echo "INCONCLUSIVE: baseline did not reach the live ION mapping regression point" >&2
	exit 1
fi
baseline_mapping=$(sed -n 's/.*ION_PROBE_HELD.*mapping=\([[:xdigit:]]\+\).*/\1/p' "$baseline_log" | tail -n 1)
if [[ -z "$baseline_mapping" ]] ||
	{ ! grep -Fq "Unable to handle kernel paging request at virtual address $baseline_mapping" "$baseline_log" &&
		! grep -Eq 'BUG: KASAN:.*use-after-free|KASAN:.*use-after-free' "$baseline_log"; }; then
	echo "INCONCLUSIVE: upstream v4.14.116 did not show a mapping fault after unmatched sync-end" >&2
	exit 1
fi
if ! grep -q 'ION_DRIVER_READY real_misc_device=/dev/ion' "$fixed_log" ||
	! grep -q 'KernelAddressSanitizer initialized' "$fixed_log" ||
	! grep -q 'ION_TEST_PASS mapping_survived_sync_end' "$fixed_log" ||
	! grep -q 'ION_GUEST_PASS' "$fixed_log" ||
	grep -Eq 'BUG: KASAN:.*use-after-free|KASAN:.*use-after-free' "$fixed_log"; then
	echo "FAIL: fixed control did not preserve the mapping through sync-end" >&2
	exit 1
fi
fixed_mapping=$(sed -n 's/.*ION_PROBE_HELD.*mapping=\([[:xdigit:]]\+\).*/\1/p' "$fixed_log" | tail -n 1)
if [[ -z "$fixed_mapping" ]] ||
	grep -Fq "Unable to handle kernel paging request at virtual address $fixed_mapping" "$fixed_log"; then
	echo "FAIL: fixed control faulted on its held mapping" >&2
	exit 1
fi
echo "PASS: upstream Linux v4.14.116 shows the ION mapping-lifetime defect; the same source with the ION fix survives."
