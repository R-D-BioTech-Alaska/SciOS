    #!/usr/bin/env bash
    # ================================================================
    #           SciOS  –  Section 1  Bootstrap Build Script
    # ================================================================
    # Generates a bootable ISO containing:
    #   • Linux 6.9 kernel  • BusyBox 1.36.1 rootfs  • GRUB bootloader
    # Works on an x86_64 Ubuntu host.  Adjust ROOT to taste.
    # ================================================================
    set -euo pipefail

    ROOT="$PWD/scios_build"          # All artefacts live here
    KERNEL_VERSION="6.9"
    BUSYBOX_VERSION="1.36.1"
    NCPU=$(nproc)

    check_deps() {
      echo "[*] Verifying host packages ..."
      local pkgs=(git build-essential bc bison flex libssl-dev libelf-dev                   grub-pc-bin grub-common xorriso qemu-system-x86 wget)
      for p in "${pkgs[@]}"; do
        dpkg -s "$p" &>/dev/null || { echo "Missing: $p"; MISSING=1; }
      done
      if [[ "${MISSING:-0}" == 1 ]]; then
        echo "Install missing packages, then re‑run."
        exit 1
      fi
    }

    prepare_dirs() {
      echo "[*] Creating build directories ..."
      mkdir -p "$ROOT"/{sources,kernel,rootfs,iso/boot/grub}
    }

    fetch_kernel() {
      if [[ ! -d "$ROOT/sources/linux" ]]; then
        echo "[*] Cloning Linux $KERNEL_VERSION ..."
        git clone --depth 1 --branch "v$KERNEL_VERSION"           https://github.com/torvalds/linux.git "$ROOT/sources/linux"
      fi
    }

    build_kernel() {
      echo "[*] Building kernel ..."
      cd "$ROOT/sources/linux"
      make mrproper
      make defconfig           
      # Ensure ext4 & initramfs built‑in
      scripts/config --enable CONFIG_EXT4_FS
      scripts/config --enable CONFIG_INITRAMFS_SOURCE
      make -j"$NCPU"
      cp arch/x86/boot/bzImage "$ROOT/kernel/vmlinuz"
      cd -
    }

    fetch_busybox() {
      if [[ ! -d "$ROOT/sources/busybox" ]]; then
        echo "[*] Downloading BusyBox $BUSYBOX_VERSION ..."
        wget -q -O "$ROOT/sources/busybox.tar.bz2"           "https://busybox.net/downloads/busybox-$BUSYBOX_VERSION.tar.bz2"
        tar -C "$ROOT/sources" -xf "$ROOT/sources/busybox.tar.bz2"
        mv "$ROOT/sources/busybox-$BUSYBOX_VERSION" "$ROOT/sources/busybox"
      fi
    }

    build_busybox() {
      echo "[*] Building BusyBox ..."
      cd "$ROOT/sources/busybox"
      make distclean
      make defconfig
      # Link statically so we don’t need glibc in the initramfs
      sed -i 's/# CONFIG_STATIC is not set/CONFIG_STATIC=y/' .config
      make -j"$NCPU"
      make CONFIG_PREFIX="$ROOT/rootfs" install
      cd -
    }

    create_rootfs() {
      echo "[*] Assembling root filesystem ..."
      cd "$ROOT/rootfs"
      mkdir -p dev proc sys etc/init.d
      # /init – first userspace process
      cat > init <<'EOF'
#!/bin/sh
mount -t proc  none /proc
mount -t sysfs none /sys
mount -t devtmpfs none /dev
echo "Welcome to SciOS – minimal bootstrap rootfs"
exec /bin/sh
EOF
      chmod +x init
      # Minimal inittab for BusyBox init (fallback)
      cat > etc/inittab <<'EOF'
::sysinit:/etc/init.d/rcS
::respawn:/bin/sh
EOF
      # rcS startup script
      cat > etc/init.d/rcS <<'EOF'
#!/bin/sh
echo "[SciOS] Boot sequence complete."
EOF
      chmod +x etc/init.d/rcS
      cd -
    }

    create_initramfs() {
      echo "[*] Creating initramfs ..."
      cd "$ROOT/rootfs"
      find . | cpio -H newc -o | gzip -9 > "$ROOT/kernel/initramfs.img"
      cd -
    }

    make_iso() {
      echo "[*] Building bootable ISO ..."
      cp "$ROOT/kernel/vmlinuz"       "$ROOT/iso/boot/vmlinuz"
      cp "$ROOT/kernel/initramfs.img" "$ROOT/iso/boot/initramfs.img"
      cat > "$ROOT/iso/boot/grub/grub.cfg" <<'EOF'
set timeout=0
set default=0
menuentry "SciOS Minimal" {
    linux /boot/vmlinuz quiet console=ttyS0
    initrd /boot/initramfs.img
}
EOF
      grub-mkrescue -o "$ROOT/scios_minimal.iso" "$ROOT/iso" >/dev/null
      echo "[*] ISO ready: $ROOT/scios_minimal.iso"
    }

    launch_qemu() {
      echo "[*] Booting SciOS in QEMU (Ctrl‑A X to exit) ..."
      qemu-system-x86_64 -m 1024 -kernel "$ROOT/kernel/vmlinuz"           -initrd "$ROOT/kernel/initramfs.img"           -nographic -append "console=ttyS0" || true
    }

    main() {
      check_deps
      prepare_dirs
      fetch_kernel
      build_kernel
      fetch_busybox
      build_busybox
      create_rootfs
      create_initramfs
      make_iso
      echo
      echo "=== Build complete ==="
      echo "Test with: qemu-system-x86_64 -cdrom $ROOT/scios_minimal.iso"
      # Uncomment to launch automatically
      # launch_qemu
    }

    main "$@"
