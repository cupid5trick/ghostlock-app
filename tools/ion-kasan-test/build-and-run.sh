#!/usr/bin/env bash

# Run the full baseline/fixed regression:
#   bash build-and-run.sh
# Or source the build blocks and compose a custom procedure:
#   source build-and-run.sh
#   export profile=custom-example
#   build-kernel "$profile" [KERNEL_SOURCE]
#   run-guest "$profile"

_ion_kasan_script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
_ion_kasan_script_path="$_ion_kasan_script_dir/$(basename -- "${BASH_SOURCE[0]}")"
_ion_kasan_repo_root=$(cd -- "$_ion_kasan_script_dir/../.." && pwd)

_ion_kasan_usage() {
	cat <<'EOF'
Usage:
  bash build-and-run.sh [--help]
      Build and boot the upstream v4.14.116 baseline and ION-fixed control.

  source build-and-run.sh
  build-kernel PROFILE [KERNEL_SOURCE]
  run-guest PROFILE
      Source the build helpers and build/boot a named custom profile. If
      KERNEL_SOURCE is omitted, the pinned upstream v4.14.116 source is used.

The sourceable helpers write their images and initramfs below
ION_KASAN_BUILD_DIR (default: ~/.tmp/ghostlock-ion-kasan-$UID).
EOF
}

_ion_kasan_validate_profile() {
	local profile=${1:?profile name is required}
	if [[ "$profile" == . || "$profile" == .. || ! "$profile" =~ ^[[:alnum:]_.-]+$ ]]; then
		echo "invalid profile name: $profile" >&2
		return 2
	fi
}

_ion_kasan_prepare_paths() {
	_ion_kasan_build_root=${ION_KASAN_BUILD_DIR:-"${HOME:?HOME must be set}/.tmp/ghostlock-ion-kasan-${UID}"}
	_ion_kasan_run_dir="$_ion_kasan_build_root/run"
	_ion_kasan_source_dir=${ION_KASAN_KERNEL_SOURCE:-"$_ion_kasan_build_root/linux-v4.14.116"}
	_ion_kasan_fixed_dir="$_ion_kasan_build_root/linux-v4.14.116-fixed-src"
	_ion_kasan_cross_compile=${CROSS_COMPILE:-aarch64-linux-gnu-}
	_ion_kasan_cross_cc="${_ion_kasan_cross_compile}gcc"
	_ion_kasan_jobs=${JOBS:-$(getconf _NPROCESSORS_ONLN)}
	_ion_kasan_kernel_ref=6d1510d86ef67e5fadb8038671e2ec43416daf7f
	_ion_kasan_apply_fix="$_ion_kasan_repo_root/tools/ion-kasan-test/apply-ion-fix.py"
	_ion_kasan_qemu=${QEMU_SYSTEM_AARCH64:-qemu-system-aarch64}
	mkdir -p "$_ion_kasan_build_root" "$_ion_kasan_run_dir"
}

_ion_kasan_require_build_tools() {
	local tool
	for tool in git make python3 "$_ion_kasan_cross_cc" cpio gzip; do
		command -v "$tool" >/dev/null || { echo "missing required tool: $tool" >&2; return 2; }
	done
}

_ion_kasan_require_guest_tools() {
	local tool
	for tool in "$_ion_kasan_qemu" timeout; do
		command -v "$tool" >/dev/null || { echo "missing required tool: $tool" >&2; return 2; }
	done
}

_ion_kasan_prepare_baseline_source() {
	_ion_kasan_require_build_tools
	if [[ ! -d "$_ion_kasan_source_dir/.git" ]]; then
		git clone --depth 1 --branch v4.14.116 https://github.com/gregkh/linux.git "$_ion_kasan_source_dir"
	fi
	local actual_ref
	actual_ref=$(git -C "$_ion_kasan_source_dir" rev-parse HEAD)
	if [[ "$actual_ref" != "$_ion_kasan_kernel_ref" ]]; then
		echo "kernel source mismatch: expected $_ion_kasan_kernel_ref, found $actual_ref at $_ion_kasan_source_dir" >&2
		return 2
	fi
	if [[ -n "$(git -C "$_ion_kasan_source_dir" status --porcelain)" ]]; then
		echo "kernel source tree has local changes: $_ion_kasan_source_dir" >&2
		return 2
	fi
}

_ion_kasan_prepare_fixed_source() {
	if [[ -e "$_ion_kasan_fixed_dir" ]] &&
		! git -C "$_ion_kasan_source_dir" worktree list --porcelain | grep -Fqx "worktree $_ion_kasan_fixed_dir"; then
		echo "refusing to modify non-managed fixed-source path: $_ion_kasan_fixed_dir" >&2
		return 2
	fi
	if [[ ! -e "$_ion_kasan_fixed_dir/.git" ]]; then
		git -C "$_ion_kasan_source_dir" worktree add --detach "$_ion_kasan_fixed_dir" "$_ion_kasan_kernel_ref"
	fi
	python3 "$_ion_kasan_apply_fix" "$_ion_kasan_fixed_dir"
}

_ion_kasan_build_kernel() {
	local label=$1
	local kernel_src=$2
	local out="$_ion_kasan_build_root/$label"
	local stage="$_ion_kasan_run_dir/$label/root"
	local module_src="$out/ion-probe-module"
	local config="$out/.config"
	mkdir -p "$out" "$stage/dev" "$module_src"
	cp "$_ion_kasan_repo_root/tools/ion-kasan-test/Makefile" \
		"$_ion_kasan_repo_root/tools/ion-kasan-test/ion_kasan_probe.c" \
		"$_ion_kasan_repo_root/tools/ion-kasan-test/ion_probe_uapi.h" "$module_src/"
	if [[ ! -f "$config" ]]; then
		make -s -C "$kernel_src" O="$out" ARCH=arm64 CROSS_COMPILE="$_ion_kasan_cross_compile" \
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
		make -s -C "$kernel_src" O="$out" ARCH=arm64 CROSS_COMPILE="$_ion_kasan_cross_compile" \
			HOSTCFLAGS=-fcommon olddefconfig
	fi
	grep -qx 'CONFIG_KASAN=y' "$config"
	grep -qx 'CONFIG_ION=y' "$config"
	grep -qx 'CONFIG_ION_SYSTEM_HEAP=y' "$config"
	grep -qx 'CONFIG_DMA_SHARED_BUFFER=y' "$config"
	grep -qx 'CONFIG_DEVTMPFS=y' "$config"
	grep -qx 'CONFIG_MODULES=y' "$config"
	if ! make -C "$kernel_src" O="$out" ARCH=arm64 CROSS_COMPILE="$_ion_kasan_cross_compile" \
		HOSTCFLAGS=-fcommon -j"$_ion_kasan_jobs" Image >"$out/kernel-build.log" 2>&1; then
		tail -n 100 "$out/kernel-build.log" >&2
		return 1
	fi
	if ! make -s -C "$kernel_src" O="$out" ARCH=arm64 CROSS_COMPILE="$_ion_kasan_cross_compile" \
		HOSTCFLAGS=-fcommon modules_prepare >>"$out/kernel-build.log" 2>&1; then
		tail -n 100 "$out/kernel-build.log" >&2
		return 1
	fi
	if ! make -s -C "$kernel_src" O="$out" ARCH=arm64 CROSS_COMPILE="$_ion_kasan_cross_compile" \
		HOSTCFLAGS=-fcommon M="$module_src" KBUILD_MODPOST_WARN=1 modules \
		>>"$out/kernel-build.log" 2>&1; then
		tail -n 100 "$out/kernel-build.log" >&2
		return 1
	fi
	install -m 0644 "$module_src/ion_kasan_probe.ko" "$stage/ion_kasan_probe.ko"
	"$_ion_kasan_cross_cc" -static -O2 -Wall -Wextra -Werror \
		"$_ion_kasan_repo_root/tools/ion-kasan-test/init.c" -o "$stage/init"
	"$_ion_kasan_cross_cc" -x c -std=gnu11 -static -O2 -Wall -Wextra -Werror \
		"$_ion_kasan_repo_root/src/core/tests/ion_backend_demo.cpp" -o "$stage/ion_backend_demo"
	chmod 0755 "$stage/init" "$stage/ion_backend_demo"
	(
		cd "$stage"
		find . -print0 | cpio --null -o --format=newc 2>/dev/null | gzip -9
	) > "$_ion_kasan_run_dir/$label-initramfs.cpio.gz"
	cp "$out/arch/arm64/boot/Image" "$_ion_kasan_run_dir/$label-Image"
	echo "$label source=$(git -C "$kernel_src" rev-parse HEAD) config=$(sha256sum "$config" | cut -d' ' -f1)"
}

_ion_kasan_run_guest() {
	local label=$1
	local log="$_ion_kasan_build_root/$label-qemu.log"
	local qemu_status=0
	if timeout --foreground 240 "$_ion_kasan_qemu" \
		-M virt -cpu cortex-a57 -smp 2 -m 2048 \
		-kernel "$_ion_kasan_run_dir/$label-Image" \
		-initrd "$_ion_kasan_run_dir/$label-initramfs.cpio.gz" \
		-append 'console=ttyAMA0 earlycon=pl011,0x9000000 panic=1 panic_on_oops=1 kasan_multi_shot=1' \
		-nographic -no-reboot > "$log" 2>&1; then
		:
	else
		qemu_status=$?
	fi
	echo "$label QEMU exit=$qemu_status log=$log"
	cat "$log"
}

_ion_kasan_build_profile() (
	set -euo pipefail
	local profile=${1:?usage: build-kernel PROFILE [KERNEL_SOURCE]}
	_ion_kasan_validate_profile "$profile"
	_ion_kasan_prepare_paths
	local kernel_src=${2:-}
	if [[ -z "$kernel_src" ]]; then
		_ion_kasan_prepare_baseline_source
		kernel_src=$_ion_kasan_source_dir
	else
		_ion_kasan_require_build_tools
	fi
	_ion_kasan_build_kernel "$profile" "$kernel_src"
)

_ion_kasan_guest_profile() (
	set -euo pipefail
	local profile=${1:?usage: run-guest PROFILE}
	_ion_kasan_validate_profile "$profile"
	_ion_kasan_prepare_paths
	_ion_kasan_require_guest_tools
	local image="$_ion_kasan_run_dir/$profile-Image"
	local initramfs="$_ion_kasan_run_dir/$profile-initramfs.cpio.gz"
	if [[ ! -f "$image" || ! -f "$initramfs" ]]; then
		echo "missing build artifacts for profile '$profile'; run build-kernel '$profile' first" >&2
		return 2
	fi
	_ion_kasan_run_guest "$profile"
)

build-kernel() {
	bash "$_ion_kasan_script_path" --_build-kernel "$@"
}

run-guest() {
	bash "$_ion_kasan_script_path" --_run-guest "$@"
}

run-full-verification() (
	set -euo pipefail
	if [[ $# -ne 0 ]]; then
		_ion_kasan_usage >&2
		return 2
	fi
	_ion_kasan_prepare_paths
	_ion_kasan_require_build_tools
	_ion_kasan_require_guest_tools
	_ion_kasan_prepare_baseline_source
	_ion_kasan_prepare_fixed_source
	_ion_kasan_build_kernel baseline "$_ion_kasan_source_dir"
	_ion_kasan_build_kernel fixed "$_ion_kasan_fixed_dir"
	local baseline_config_hash
	local fixed_config_hash
	baseline_config_hash=$(sha256sum "$_ion_kasan_build_root/baseline/.config" | cut -d' ' -f1)
	fixed_config_hash=$(sha256sum "$_ion_kasan_build_root/fixed/.config" | cut -d' ' -f1)
	if [[ "$baseline_config_hash" != "$fixed_config_hash" ]]; then
		echo "FAIL: baseline and fixed kernel configs differ" >&2
		echo "baseline config=$baseline_config_hash" >&2
		echo "fixed config=$fixed_config_hash" >&2
		return 1
	fi
	echo "CONFIGS_MATCH sha256=$baseline_config_hash"
	_ion_kasan_run_guest baseline
	_ion_kasan_run_guest fixed

	local baseline_log="$_ion_kasan_build_root/baseline-qemu.log"
	local fixed_log="$_ion_kasan_build_root/fixed-qemu.log"
	if ! grep -q 'ION_DRIVER_READY real_misc_device=/dev/ion' "$baseline_log" ||
		! grep -q 'KernelAddressSanitizer initialized' "$baseline_log" ||
		! grep -q 'ION_ALLOC_OK' "$baseline_log" ||
		! grep -q 'ION_SYNC_END_OK' "$baseline_log" ||
		! grep -q 'ION_PROBE_HELD' "$baseline_log"; then
		echo "INCONCLUSIVE: baseline did not reach the live ION mapping regression point" >&2
		return 1
	fi
	local baseline_mapping
	baseline_mapping=$(sed -n 's/.*ION_PROBE_HELD.*mapping=\([[:xdigit:]]\+\).*/\1/p' "$baseline_log" | tail -n 1)
	if [[ -z "$baseline_mapping" ]] ||
		{ ! grep -Fq "Unable to handle kernel paging request at virtual address $baseline_mapping" "$baseline_log" &&
			! grep -Eq 'BUG: KASAN:.*use-after-free|KASAN:.*use-after-free' "$baseline_log"; }; then
		echo "INCONCLUSIVE: upstream v4.14.116 did not show a mapping fault after unmatched sync-end" >&2
		return 1
	fi
	if ! grep -q 'ION_DRIVER_READY real_misc_device=/dev/ion' "$fixed_log" ||
		! grep -q 'KernelAddressSanitizer initialized' "$fixed_log" ||
		! grep -q 'ION_TEST_PASS mapping_survived_sync_end' "$fixed_log" ||
		! grep -q 'ION_GUEST_PASS' "$fixed_log" ||
		grep -Eq 'BUG: KASAN:.*use-after-free|KASAN:.*use-after-free' "$fixed_log"; then
		echo "FAIL: fixed control did not preserve the mapping through sync-end" >&2
		return 1
	fi
	local fixed_mapping
	fixed_mapping=$(sed -n 's/.*ION_PROBE_HELD.*mapping=\([[:xdigit:]]\+\).*/\1/p' "$fixed_log" | tail -n 1)
	if [[ -z "$fixed_mapping" ]] ||
		grep -Fq "Unable to handle kernel paging request at virtual address $fixed_mapping" "$fixed_log"; then
		echo "FAIL: fixed control faulted on its held mapping" >&2
		return 1
	fi
	echo "PASS: upstream Linux v4.14.116 shows the ION mapping-lifetime defect; the same source with the ION fix survives."
)

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
	case "${1:-}" in
		--help|-h) _ion_kasan_usage ;;
		"") run-full-verification ;;
		--_build-kernel) shift; _ion_kasan_build_profile "$@" ;;
		--_run-guest) shift; _ion_kasan_guest_profile "$@" ;;
		*) _ion_kasan_usage >&2; exit 2 ;;
	esac
fi
