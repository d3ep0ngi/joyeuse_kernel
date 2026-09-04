#!/usr/bin/env bash
# miatoll / joyeuse kernel build  (LineageOS sm6250, Linux 4.14.336)
set -euo pipefail

ROOT="${ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
KDIR="$ROOT/kernel"
OUT="$KDIR/out"
AK3="$ROOT/AnyKernel3"
JOBS="${JOBS:-$(nproc)}"
DEFCONFIG="${DEFCONFIG:-vendor/xiaomi/miatoll_defconfig}"

# --- toolchains (user-provided, /mnt/Hawai or CI overrides) --------------------------------
TC_CLANG="${TC_CLANG:-/mnt/Hawai/toolchains/Clang-23.0.0git-20260130}"                         # ZyC clang 23 — matched all working builds (Sep 1/2)
TC_A64="${TC_A64:-/mnt/Hawai/toolchains/arm-gnu-toolchain-15.2.rel1-x86_64-aarch64-none-linux-gnu}"
TC_A32="${TC_A32:-/mnt/Hawai/toolchains/arm-gnu-toolchain-15.2.rel1-x86_64-arm-none-eabi}"

export PATH="$TC_CLANG/bin:$TC_A64/bin:$TC_A32/bin:$PATH"
export KBUILD_BUILD_USER="deepongi"
export KBUILD_BUILD_HOST="deepongi-labs"
export ARCH=arm64 SUBARCH=arm64

# --- ccache (warm cache on the dedicated 50G nvme partition) ---------------
export CCACHE_DIR="${CCACHE_DIR:-$ROOT/.ccache}"
# The shared cache volume can be mounted read-only; temporary preprocessor
# output must remain writable for reproducible local builds.
export CCACHE_TEMPDIR="${CCACHE_TEMPDIR:-$ROOT/.ccache-tmp}"
mkdir -p "$CCACHE_DIR" "$CCACHE_TEMPDIR"
export CCACHE_COMPILERCHECK="content"   # clang is a git build; mtime alone lies
export CCACHE_SLOPPINESS="time_macros,include_file_mtime,include_file_ctime,file_stat_matches"
CC_WRAP="ccache clang"

# kernel 4.14 predates LLVM=1 (added in 5.7) -> old-style CC=clang.
# The in-tree DTC is 1.4.4, too old for top-level `&label{}` overlay syntax
# used by the miatoll *-overlay.dts files -> point kbuild at the system DTC 1.8.1.
MAKE_ARGS=(
  O=out ARCH=arm64
  CC="$CC_WRAP"
  CLANG_TRIPLE=aarch64-none-linux-gnu-
  CROSS_COMPILE=aarch64-none-linux-gnu-
  CROSS_COMPILE_ARM32=arm-none-eabi-
  LD=ld.lld
  AR=llvm-ar NM=llvm-nm
  OBJCOPY=llvm-objcopy OBJDUMP=llvm-objdump STRIP=llvm-strip
  HOSTCC="$CC_WRAP" HOSTCXX="ccache clang++"
  DTC_EXT="$(command -v dtc)"
)

cd "$KDIR"
echo "==> clang : $(clang --version | head -1)"
echo "==> a64   : $(aarch64-none-linux-gnu-ld --version | head -1)"
echo "==> dtc   : $(dtc --version)"
echo "==> ccache: $CCACHE_DIR ($(du -sh "$CCACHE_DIR" 2>/dev/null | cut -f1) warm)"
echo "==> config: $DEFCONFIG"

make "${MAKE_ARGS[@]}" "$DEFCONFIG"

echo "==> tuning .config"
CFG=(-d LTO_CLANG -d THINLTO -d LOCALVERSION_AUTO -d CC_STACKPROTECTOR_STRONG -d EXFAT_FS --set-str LOCALVERSION "-PECINTA_MEMEK")
CFG+=(
  -e USERFAULTFD -e CRYPTO_CHACHA20POLY1305 -e DEBUG_LIST
  -e HAVE_MOVE_PMD -e HAVE_MOVE_PUD -e XFRM_MIGRATE -e SONY_FF
  -e TRACE_GPU_MEM -e UNICODE
)
if [ "${WITH_KSU:-0}" = "1" ]; then
  # KernelSU-Next `legacy` branch: the only line that builds on 4.14
  # (v3.x mainline needs syscall_fn_t, an arm64 syscall-wrapper type added in 4.19).
  CFG+=(-e KSU -e KALLSYMS -e KALLSYMS_ALL -e OVERLAY_FS)
  # No SuSFS: upstream susfs4ksu only ships v1.5.5 for kernel-4.14 (2.x is GKI-only),
  # and KernelSU-Next v3.2.0-legacy carries no susfs code at all. The kernel tree's
  # own susfs v1.5.5 sources stay dormant -- every call site is #ifdef CONFIG_KSU_SUSFS
  # and that symbol no longer exists in any Kconfig, so it is never set.
  CFG+=(-d KSU_SUSFS)
  if [ "${HOOK_MODE:-kprobes}" = "manual" ]; then
    # Manual hooks: the kernel tree calls ksu_handle_* directly. Kbuild gates on
    # `grep ksu_handle_sys_reboot kernel/reboot.c` and $(error)s if it is missing.
    CFG+=(-e KSU_MANUAL_HOOK -d KSU_KPROBES_HOOK)
    echo "    (KernelSU-Next legacy + MANUAL hooks)"
  else
    # tracepoint+kretprobe path; needs FTRACE_SYSCALLS to actually intercept.
    CFG+=(-e KSU_KPROBES_HOOK -d KSU_MANUAL_HOOK
          -e KPROBES -e KPROBE_EVENTS -e KRETPROBES -e FTRACE_SYSCALLS)
    echo "    (KernelSU-Next legacy + kprobes hook)"
  fi
else
  CFG+=(-d KSU -d KSU_SUSFS)   # KSU Kconfig is `default y`; keep it off unless asked
fi
./scripts/config --file out/.config "${CFG[@]}"
make "${MAKE_ARGS[@]}" olddefconfig

echo "==> building"
make "${MAKE_ARGS[@]}" -j"$JOBS" Image.gz-dtb dtbs

IMG="$OUT/arch/arm64/boot/Image.gz-dtb"
[ -f "$IMG" ] || { echo "!! no Image.gz-dtb produced"; exit 1; }
echo "==> built $IMG ($(du -h "$IMG" | cut -f1))"

echo "==> packaging AnyKernel3"
cp "$IMG" "$AK3/Image.gz-dtb"
# stitch the four miatoll variant overlays into a dtbo.img if mkdtimg is around
DTBO_DIR="$OUT/arch/arm64/boot/dts/qcom"
if command -v mkdtimg >/dev/null && ls "$DTBO_DIR"/*-overlay.dtbo >/dev/null 2>&1; then
  mkdtimg create "$AK3/dtbo.img" --page_size=4096 "$DTBO_DIR"/*-overlay.dtbo && echo "   + dtbo.img"
fi
STAMP="$(date +%Y%m%d-%H%M)"
SUFFIX="stock"
[ "${WITH_KSU:-0}" = "1" ] && SUFFIX="KSUNext-${HOOK_MODE:-kprobes}"
ZIP="$ROOT/enhance-kernel-miatoll-$SUFFIX-$STAMP.zip"
( cd "$AK3" && zip -r9 "$ZIP" . -x '.git*' '*.md' 'README*' >/dev/null )
echo "==> DONE: $ZIP"
ls -lh "$ZIP"

if [ -f "$ROOT/backup_boot.img" ] && [ -x "$ROOT/magiskboot" ]; then
  echo "==> packaging fastboot boot_susfs.img"
  rm -rf "$ROOT/boot_susfs_tmp"
  mkdir -p "$ROOT/boot_susfs_tmp"
  (
    cd "$ROOT/boot_susfs_tmp"
    "$ROOT/magiskboot" unpack "$ROOT/backup_boot.img"
    "$ROOT/magiskboot" split "$IMG"
    mv -f kernel_dtb dtb
    "$ROOT/magiskboot" repack "$ROOT/backup_boot.img" "$ROOT/boot_susfs.img"
  )
  rm -rf "$ROOT/boot_susfs_tmp"
  echo "==> DONE: $ROOT/boot_susfs.img"
  ls -lh "$ROOT/boot_susfs.img"
else
  echo "==> skipping fastboot boot_susfs.img repack (backup_boot.img or magiskboot missing)"
fi

