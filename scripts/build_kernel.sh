#!/bin/bash
# Kernel Build Script for AI-OS
# Optimizes for i7/AVX2 and Low Latency

KERNEL_VERSION="6.6.15" # Check kernel.org for latest
build_dir="$HOME/kernel_build"

echo "Installing dependencies..."
sudo pacman -S --needed base-devel curl xmlto kmod inetutils bc libelf git pahole cpio perl tar xz

mkdir -p "$build_dir"
cd "$build_dir"

if [ ! -d "linux-$KERNEL_VERSION" ]; then
    echo "Downloading Kernel $KERNEL_VERSION..."
    curl -LO "https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-$KERNEL_VERSION.tar.xz"
    tar -xvf "linux-$KERNEL_VERSION.tar.xz"
fi

cd "linux-$KERNEL_VERSION"

echo "Cleaning previous config..."
make mrproper

echo "Copying current config as base..."
zcat /proc/config.gz > .config

echo "Setting AI-OS Optimizations..."
# script to modify .config using ./scripts/config
./scripts/config --enable CONFIG_SCHED_EEVDF
./scripts/config --enable CONFIG_PREEMPT_VOLUNTARY
./scripts/config --disable CONFIG_PREEMPT_NONE
./scripts/config --disable CONFIG_PREEMPT
./scripts/config --set-val CONFIG_HZ 300
./scripts/config --enable CONFIG_NO_HZ_FULL
./scripts/config --enable CONFIG_CPU_FREQ_GOV_PERFORMANCE
./scripts/config --enable CONFIG_TRANSPARENT_HUGEPAGE_MADVISE
./scripts/config --disable CONFIG_NUMA
./scripts/config --disable CONFIG_SPECULATION_MITIGATIONS

echo "Stripping Modules (Ensure all devices are plugged in!)..."
# This step requires user interaction usually, but we can force it with yes
# yes "" | make localmodconfig

echo "Starting Build on $(nproc) cores..."
make -j$(nproc) LOCALVERSION=-aios

echo "Installing Modules..."
sudo make modules_install

echo "Installing Kernel..."
sudo make install

echo "Kernel Build Complete. Update bootloader to use new kernel."
