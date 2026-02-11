# AI-OS Design Blueprint

**Version**: 1.0
**Target Hardware**: Intel Core i7 (AVX2), 16-32GB RAM, NVMe SSD, No GPU.
**Goal**: Maximum CPU inference performance for LLMs (llama.cpp, GGUF).

---

## 1. Architecture Design

### 1.1 Bootloader
*   **Recommendation**: **systemd-boot** (if UEFI) or **GRUB** (legacy/universal).
*   **Reasoning**: `systemd-boot` is significantly simpler and faster to boot on modern UEFI systems than GRUB. It has less code surface.
*   **Config**: `bootctl install`. Set `timeout 0` in `loader.conf` for instant boot.

### 1.2 Init System
*   **Recommendation**: **systemd** (Minimal Profile).
*   **Reasoning**: While `OpenRC` or `runit` are lighter memory-wise, `systemd` offers superior **cgroups v2** resource management, which is critical for pinning AI processes, managing memory limits, and isolating background tasks from the inference engine.
*   **Optimization**: Disable all non-essential units (print server, sound, bluetooth, modem manager, avahi, etc.).
    *   Command: `systemctl mask bluetooth.service cups.service avahi-daemon.service ModemManager.service`

### 1.3 Kernel Configuration Strategy
*   **Base**: **Linux-TKG** (highly optimized custom kernel scripts) or **Mainstream Stable**.
*   **Key Optimizations**:
    *   **CPU Scheduler**: `EEVDF` (Default in 6.6+) or `Bore` (Burst-Oriented Response Enhancer) for responsiveness.
    *   **Preemption Model**: `CONFIG_PREEMPT_VOLUNTARY` (Balance) or `CONFIG_PREEMPT` (Low Latency). For pure inference, `VOLUNTARY` is often sufficient and has higher throughput.
    *   **Timer Frequency**: `300Hz` (Server) or `100Hz`. Avoid `1000Hz` to reduce interrupt overhead.
    *   **Tickless System**: `CONFIG_NO_HZ_FULL` (Adaptive ticks) to reduce OS jitter on inference cores.
    *   **Stripping**: Use `make localmodconfig` to disable all unused drivers.

### 1.4 Filesystem
*   **Recommendation**: **XFS** or **EXT4** (tuned).
*   **Layout**:
    *   `/boot`: VFAT (UEFI) - 512MB
    *   `/`: XFS - Remaining Space. (Fast for parallel I/O, proficient with large files like GGUF models).
    *   **Mount Options**: `noatime, nodiratime, discard=async` (for NVMe), `commit=60`.

### 1.5 Memory Strategy
*   **HugePages**: **Transparent Huge Pages (THP)** set to `madvise`.
    *   *Reasoning*: `always` can cause latency spikes during defrag. `madvise` allows `llama.cpp` to request them explicitly.
*   **Swap/ZRAM**:
    *   **ZRAM**: **Mandatory**.
    *   **Algorithm**: `zstd` (fastest decompression).
    *   **Size**: `zram-generator` with `zram-fraction = 1.0` (100% of RAM size as swap, compressed).


---

## 2. Build Strategy

### 2.1 Base System: Custom Arch Linux
**Why Arch?**: Provides `pacstrap` for a minimal base, bleeding-edge kernels, and `makepkg` for optimizing builds.
**Step-by-Step Implementation**:

1.  **Boot Arch ISO**.
2.  **Partition NVMe**:
    ```bash
    parted /dev/nvme0n1 mklabel gpt
    parted /dev/nvme0n1 mkpart "ESP" fat32 1MiB 513MiB
    parted /dev/nvme0n1 set 1 esp on
    parted /dev/nvme0n1 mkpart "AI_ROOT" xfs 513MiB 100%
    ```
3.  **Format & Mount**:
    ```bash
    mkfs.fat -F32 /dev/nvme0n1p1
    mkfs.xfs -f /dev/nvme0n1p2
    mount /dev/nvme0n1p2 /mnt
    mkdir /mnt/boot
    mount /dev/nvme0n1p1 /mnt/boot
    ```
4.  **Bootstrap Minimal Base**:
    ```bash
    pacstrap /mnt base base-devel linux-firmware intel-ucode vim git networkmanager
    # Note: excluding 'linux' kernel package to build our own later, or use 'linux-zen' temporarily.
    ```
5.  **Chroot & Configure**:
    ```bash
    genfstab -U /mnt >> /mnt/etc/fstab
    arch-chroot /mnt
    ```

### 2.2 Compiler Optimization Strategy
**Goal**: Build software specifically for your i7 AVX2 CPU.

**Target Compiler**: GCC 13+ or Clang 16+.
**`/etc/makepkg.conf` Configuration** (For Arch Build System):

```bash
# CPU Architecture: Auto-detect host CPU features
CFLAGS="-march=native -O3 -pipe -fno-plt -fopenmp"
CXXFLAGS="${CFLAGS}"
# Linker optimizations
LDFLAGS="-Wl,-O1,--sort-common,--as-needed,-z,relro,-z,now"
# Parallel Compilation
MAKEFLAGS="-j$(nproc)"
# Compression (Fastest for build speed, or ZSTD for package size)
COMPRESSZST=(zstd -c -T0 --ultra -20 -)
```

**Instruction Set Risks**:
*   `-march=native`: Binaries will **NOT** run on older CPUs. (Acceptable for this custom rig).
*   `-O3`: Can occasionally break strict compliance or bloat binary size, but essential for vectorization in ML.
*   `-flto`: Increases build time significantly. Use selectively for `llama.cpp` rather than globally if stability is key.
*   `-ffast-math`: **DANGEROUS** for some ML ops that rely on precise float behavior. Use with caution. `llama.cpp` generally handles its own math flags.

---

## 3. Kernel Optimization (The "AI Core")

### 3.1 Custom Kernel Build Guide
We will use the **Linux TKG** patches or build from source.

**Configuration Table**:
| Category | Config Option | Value | Reason |
| :--- | :--- | :--- | :--- |
| **Scheduler** | `CONFIG_SCHED_EEVDF` | `y` | Low latency, fair deadlines (New standard). |
| **Preemption** | `CONFIG_PREEMPT_VOLUNTARY` | `y` | Max throughput for batch tokens. |
| **Timer** | `CONFIG_HZ` | `300` | Reduced interrupt overhead. |
| **Tick** | `CONFIG_NO_HZ_FULL` | `y` | Adaptive ticks for dedicated coding. |
| **CPU Freq** | `CONFIG_CPU_FREQ_GOV_PERFORMANCE` | `y` | Prevent clock down-scaling. |
| **HugePages** | `CONFIG_TRANSPARENT_HUGEPAGE` | `y` | Essential for large Memory mapping. |
| **NUMA** | `CONFIG_NUMA` | `n` | Disable if single socket i7 (Check usage). |
| **Mitigations** | `CONFIG_SPECULATION_MITIGATIONS` | `n` | **Legacy/Unsafe**: Boosts perf ~5-15%. |

**Steps**:
1.  Clone Kernel Source: `git clone https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git`
2.  Import Config: `zcat /proc/config.gz > .config` (from live ISO)
3.  Strip Modules: `make localmodconfig` (Must have all USB/peripherals plugged in!)
4.  Menuconfig: `make menuconfig` (Apply table changes above).
5.  Build: `make -j$(nproc) && make modules_install && make install`


---

## 4. LLM Runtime Optimization

### 4.1 llama.cpp Specifics

**Build Command**:
```bash
# Force specific CPU features (AVX2 is critical)
make -j$(nproc) LLAMA_AVX2=1 LLAMA_FMA=1 LLAMA_F16C=1
```

**Thread Tuning**:
*   **Equation**: `N_THREADS = Physical Cores` (usually 6 or 8 for i7).
*   **Verify**: Run `lscpu` and look for `Core(s) per socket`.
*   avoid using logical cores (Hyperthreading) for inference as existing threads compete for L1/L2 cache and FPU/AVX units.

**Model Strategy**:
*   **Quantization**: Use **Q4_K_M** or **Q5_K_M**.
    *   *Q4_K_M*: Sweet spot for speed/quality.
    *   *Q5_K_M*: Better coherence, ~15% slower.
*   **MMap**: Keep `mmap` enabled.

**Systemd Service for Ollama (Example)**:
Create `/etc/systemd/system/ollama.service`:
```ini
[Unit]
Description=Ollama Service (High Priority)
After=network.target

[Service]
ExecStart=/usr/bin/ollama serve
User=ai-user
Group=ai-user
Restart=always
# Optimization priorities
CPUSchedulingPolicy=batch
Nice=-5
MemoryHigh=28G  # Leave 4GB for OS
OOMScoreAdjust=-500 # Don't kill this

[Install]
WantedBy=default.target
```


---

## 5. System Hardening & Minimalization

### 5.1 Service Reduction
**Goal**: Zero background CPU usage locally.
*   **Method**:
    ```bash
    # Check running services
    systemctl list-units --type=service --state=running
    # Disable typical desktop bloat
    systemctl disable --now wpa_supplicant (if using ethernet) accounts-daemon upower switcheroo-control
    ```

### 5.2 Kernel Command Line Security
Modify `/boot/loader/entries/arch.conf` (for systemd-boot):
```text
options root=PARTUUID=... rw auditing=0 logic=no mitigations=off nowatchdog nmi_watchdog=0
```
*   `auditing=0`: Saves syscall overhead.
*   `mitigations=off`: **WARNING**: Disables CPU vulnerability patches. Adds 5-20% perf. **Only for offline/trusted networks.**
*   `nowatchdog`: Stops hardware watchdog polling.

### 5.3 Logging
*   **Limit Journal**:
    Edit `/etc/systemd/journald.conf`:
    ```ini
    Storage=volatile
    SystemMaxUse=50M
    RuntimeMaxUse=50M
    ```

---

## 6. Performance Benchmark Plan

### 6.1 Tools
*   **llama-bench**: Native tool in llama.cpp (Best for end-to-end AI perf).
*   **htop / btop**: For real-time core usage monitoring.
*   **perf**: Linux kernel profiler.
*   **intel_gpu_top**: (If using iGPU for UI, though we generally ignore it).

### 6.2 Methodology
**Baseline vs Custom**:
1.  **Stock**: Install Ubuntu 24.04, compile llama.cpp generic. Run benchmark.
2.  **AI-OS**: Boot custom kernel, idle CPU < 0.1%. Run benchmark.

**Command**:
```bash
# Test token generation speed (Generation is memory bound, Prompt is compute bound)
./llama-bench -m model.gguf -p 512,1024 -n 128 -t $(nproc)
```

**Success Metric**:
*   **Tokens/Sec (tg/s)**: Higher is better.
*   **Prompt Eval (t/s)**: Higher is better.
*   **System Jitter**: Measure variance in generation time (Standard Deviation). Lower is better.

---

## 7. Future Upgrade Path

### 7.1 Adding a dedicated GPU
If adding an NVIDIA GPU later:
1.  **Install Drivers**: `pacman -S nvidia-open-dkms nvidia-utils cuda`.
2.  **Recompile llama.cpp**:
    ```bash
    make clean
    make LLAMA_CUBLAS=1
    ```
3.  **Kernel**: No change needed if utilizing standard modules, or enable `CONFIG_PCI_STUB` for pass-through setups.

---

## 8. Structured Roadmap

### Phase 1: Research & Prep
*   [ ] Verify i7 Gen (Broadwell? Skylake?) for AVX-512 support (unlikely strictly AVX2).
*   [ ] Select "AI-OS" name (e.g., **"NeuroKernel"**).

### Phase 2: Build Base System
*   [ ] Boot Arch ISO.
*   [ ] Partition NVMe (ESP + XFS Root).
*   [ ] Pacstrap minimal base + git + base-devel.

### Phase 3: Kernel Optimization
*   [ ] Clone `linux-tkg` or mainline.
*   [ ] Run `make localmodconfig` with all hardware attached.
*   [ ] Enable `CONFIG_SCHED_EEVDF`, `CONFIG_PREEMPT_VOLUNTARY`, `CONFIG_HZ_300`.
*   [ ] Compile and Install.

### Phase 4: AI Runtime Optimization
*   [ ] Git clone `llama.cpp`.
*   [ ] Compile with `-march=native -O3`.
*   [ ] Configure HugePages (`sysctl vm.nr_hugepages` or THP).
*   [ ] Set up `ollama.service` with cgroups priority.

### Phase 5: Benchmarking
*   [ ] Run `llama-bench`.
*   [ ] Compare against Ubuntu baseline.
*   [ ] Tune `Sysctl` (swappiness, dirty_ratio) until diminishing returns.

### Phase 6: Final Hardening & Packaging
*   [ ] Disable SSH (if local only).
*   [ ] Set up Read-Only Root overlay (optional).
*   [ ] Create install script / ISO.

---

## 9. AI-OS Distribution Concept

**Name**: **"Synapse OS"**
**Tagline**: *Bare-metal Intelligence.*

**Key Features**:
*   **Read-Only Root**: Uses `overlayfs` for the root system to prevent breakage. User data lives in `/var/ai-data`.
*   **"Neural Control Panel"**: A lightweight TUI (Text User Interface) written in Go or Rust (using `ratatui`) that shows:
    *   Active Model
    *   Tokens/Sec Realtime
    *   VRAM/RAM Split
    *   Core Loading map.
*   **Container Isolation**: Models run in `systemd-nspawn` containers for security if downloading potentially unsafe GGUFs.
*   **Package Manager Strategy**:
    *   System: `pacman` (Immutable base updates).
    *   AI: `pip` / `conda` (Isolated in specific environments).

