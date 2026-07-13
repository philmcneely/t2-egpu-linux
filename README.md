# RX 6800 eGPU on Mac Mini 2018 (T2) — Linux Setup Guide

Running an AMD RX 6800 over Thunderbolt 3 on a Mac Mini 2018 with Ubuntu Linux for LLM inference. This guide covers the full stack: kernel parameters, PCIe BAR programming, a custom kernel module, automated boot, and Ollama with ROCm.

## Hardware

- **Mac Mini 2018** (Macmini8,1) with T2 security chip
- **AMD Radeon RX 6800** (Navi 21, gfx1030) — NOT the XT
- **AKiTiO Node Titan** Thunderbolt 3 eGPU enclosure
- **Ubuntu 24.04** with [T2 Linux kernel](https://github.com/t2linux/linux-t2-patches) (7.0.9-1-t2-noble)

## The Problem

The T2 Mac Mini's firmware allocates only 224MB of prefetchable memory for the entire Thunderbolt domain. The RX 6800's BAR 0 needs at minimum 256MB. The GPU shows up in `lspci` but the amdgpu driver can't enable it — the kernel's PCIe resource tree doesn't have a valid memory window.

On top of that, the kernel caches bridge resources during initial PCI scan and never updates them. Even if you reprogram the hardware registers with `setpci`, the kernel's internal `struct resource` still reflects the original (broken) values. The amdgpu driver checks the kernel's resource tree, not the hardware registers, so it refuses to enable the device.

The solution is a three-layer approach:
1. **setpci** — Program the hardware registers (bridge pref windows + GPU BAR 0)
2. **Kernel module** — Patch the kernel's internal resource tree to match
3. **Systemd service** — Automate everything on boot

## Prerequisites

Install the T2 Linux kernel from [t2linux.org](https://wiki.t2linux.org). The generic Ubuntu kernel may work for basic functionality but the T2 kernel includes drivers for the Mac's keyboard, trackpad, and other T2-specific hardware.

```bash
# Verify you're on the T2 kernel
uname -r
# Should show something like: 7.0.9-1-t2-noble
```

You'll need kernel headers for building the module:
```bash
sudo apt install linux-headers-$(uname -r) build-essential pciutils
```

## Step 1: GRUB Configuration

Edit `/etc/default/grub`:

```bash
sudo nano /etc/default/grub
```

Set these parameters:

```
GRUB_DEFAULT=0
GRUB_TIMEOUT_STYLE=hidden
GRUB_TIMEOUT=5
GRUB_CMDLINE_LINUX_DEFAULT="quiet splash vfio-pci.ids=8086:3e9b amdgpu.dc=0 amdgpu.runpm=0 amdgpu.rebar=0"
GRUB_CMDLINE_LINUX="pm_async=off intel_iommu=on iommu=pt pci=realloc pcie_ports=native pcie_aspm=off pcie_port_pm=off"
GRUB_RECORDFAIL_TIMEOUT=5
```

### What each parameter does

**GRUB_CMDLINE_LINUX_DEFAULT:**
| Parameter | Purpose |
|-----------|---------|
| `vfio-pci.ids=8086:3e9b` | Binds Intel UHD 630 iGPU to vfio-pci so it doesn't conflict with the eGPU. Machine runs headless — SSH only. |
| `amdgpu.dc=0` | Disables Display Core. We're doing compute, not display. |
| `amdgpu.runpm=0` | Disables runtime power management. eGPU must stay powered. |
| `amdgpu.rebar=0` | **CRITICAL.** Disables Resizable BAR. Without this, amdgpu auto-resizes BAR 0 from 256MB to 16GB, which overflows the bridge windows and causes a kernel BUG (GART page table corruption). |

**GRUB_CMDLINE_LINUX:**
| Parameter | Purpose |
|-----------|---------|
| `pm_async=off` | Synchronous power management during boot — prevents TB race conditions |
| `intel_iommu=on iommu=pt` | IOMMU in passthrough mode — required for vfio-pci |
| `pci=realloc` | Allows kernel to reallocate PCI resources |
| `pcie_ports=native` | Native PCIe port services — required for TB hotplug |
| `pcie_aspm=off` | **CRITICAL.** Disables PCIe Active State Power Management. Without this, the Thunderbolt link fails to establish. |
| `pcie_port_pm=off` | Disables PCIe port power management |

**GRUB_RECORDFAIL_TIMEOUT=5:** If the previous boot failed (crash, power loss), Ubuntu's GRUB normally waits **forever** for keyboard input. For a headless machine, this means it never boots. This setting limits the wait to 5 seconds.

Apply GRUB changes:
```bash
sudo update-grub
```

## Step 2: Blacklist amdgpu

The amdgpu driver must NOT auto-load at boot. It needs to load AFTER the bridges and BARs are programmed. Create `/etc/modprobe.d/amdgpu-egpu.conf`:

```bash
sudo tee /etc/modprobe.d/amdgpu-egpu.conf << 'EOF'
blacklist amdgpu
options amdgpu rebar=0 dc=0 runpm=0 pcie_gen_cap=0x40000
EOF
```

The `pcie_gen_cap=0x40000` limits PCIe link speed — Thunderbolt 3 can't sustain full PCIe Gen 4 speeds anyway.

## Step 3: Build the Kernel Module

The kernel module patches the kernel's internal resource tree so the amdgpu driver sees valid memory regions. Without this, `setpci` alone isn't enough — the kernel ignores hardware register changes.

Create `~/egpu-bar-fix/egpu_bar.c`:

```c
#include <linux/module.h>
#include <linux/pci.h>

#define GPU_VENDOR  0x1002
#define GPU_DEVICE  0x73bf
#define BRIDGE_DEV  0x1479

#define BAR0_ADDR   0x4010000000ULL
#define BAR0_SIZE   0x10000000ULL       /* 256MB */
#define PREF_START  0x4010000000ULL
#define PREF_END    (0x4010000000ULL + 0x10000000ULL - 1)

static struct pci_dev *saved_bridge;
static struct pci_dev *saved_gpu;
static resource_size_t orig_bridge_start;
static resource_size_t orig_bridge_end;
static unsigned long orig_bridge_flags;

static int __init egpu_bar_init(void)
{
    struct pci_dev *gpu, *bridge;
    struct resource *bridge_pref, *bar0;
    int pref_idx;

    gpu = pci_get_device(GPU_VENDOR, GPU_DEVICE, NULL);
    if (!gpu) {
        pr_err("egpu_bar: RX 6800 not found\n");
        return -ENODEV;
    }

    bridge = pci_upstream_bridge(gpu);
    if (!bridge) {
        pr_err("egpu_bar: no upstream bridge for GPU\n");
        pci_dev_put(gpu);
        return -ENODEV;
    }

    /* PCI_BRIDGE_RESOURCES + 2 = prefetchable memory window (index 15) */
    pref_idx = PCI_BRIDGE_RESOURCES + 2;
    bridge_pref = &bridge->resource[pref_idx];

    pr_info("egpu_bar: GPU at %s, bridge at %s\n",
        pci_name(gpu), pci_name(bridge));
    pr_info("egpu_bar: bridge pref before: %pR\n", bridge_pref);
    pr_info("egpu_bar: GPU BAR 0 before: %pR\n", &gpu->resource[0]);

    /* Save original bridge pref resource for cleanup */
    orig_bridge_start = bridge_pref->start;
    orig_bridge_end = bridge_pref->end;
    orig_bridge_flags = bridge_pref->flags;

    /* Release existing resource if it has a parent */
    if (bridge_pref->parent)
        release_resource(bridge_pref);

    /* Patch bridge pref to cover our BAR range in 64-bit space */
    bridge_pref->start = PREF_START;
    bridge_pref->end = PREF_END;
    bridge_pref->flags = IORESOURCE_MEM | IORESOURCE_PREFETCH |
                 IORESOURCE_MEM_64;

    /* Patch GPU BAR 0 resource with correct address and parent pointer */
    bar0 = &gpu->resource[0];
    bar0->start = BAR0_ADDR;
    bar0->end = BAR0_ADDR + BAR0_SIZE - 1;
    bar0->flags = IORESOURCE_MEM | IORESOURCE_PREFETCH |
              IORESOURCE_MEM_64 | IORESOURCE_SIZEALIGN;
    bar0->parent = bridge_pref;

    pr_info("egpu_bar: bridge pref after: %pR\n", bridge_pref);
    pr_info("egpu_bar: GPU BAR 0 after: %pR (parent=%pR)\n",
        bar0, bar0->parent);

    saved_bridge = bridge;
    saved_gpu = gpu;
    pci_dev_get(bridge);

    return 0;
}

static void __exit egpu_bar_exit(void)
{
    if (saved_gpu) {
        saved_gpu->resource[0].parent = NULL;
        saved_gpu->resource[0].start = 0;
        saved_gpu->resource[0].end = 0;
        saved_gpu->resource[0].flags = 0;
        pci_dev_put(saved_gpu);
    }

    if (saved_bridge) {
        int pref_idx = PCI_BRIDGE_RESOURCES + 2;
        struct resource *bp = &saved_bridge->resource[pref_idx];
        bp->start = orig_bridge_start;
        bp->end = orig_bridge_end;
        bp->flags = orig_bridge_flags;
        pci_dev_put(saved_bridge);
    }

    pr_info("egpu_bar: unloaded, resources restored\n");
}

module_init(egpu_bar_init);
module_exit(egpu_bar_exit);
MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("Fix eGPU BAR 0 resource for T2 Mac Mini");
MODULE_AUTHOR("Phil McNeely");
```

### Key addresses explained

- **`0x4010000000`** — GPU BAR 0 address, placed in the host bridge's 64-bit window `[0x4000000000-0x7fffffffff]`. Offset by 256MB to avoid conflict with Intel HDA controller at `0x4000000000`.
- **`0x10000000`** — 256MB BAR size (BAR 0 minimum for Navi 21).
- **`PCI_BRIDGE_RESOURCES + 2`** — Kernel resource index for the bridge's prefetchable memory window. With `CONFIG_PCI_IOV`, `PCI_BRIDGE_RESOURCES = 13`, so `pref_idx = 15`.

### Why the parent pointer matters

The kernel's `pci_enable_resources()` checks that each BAR's resource has a non-NULL `parent`. Without `bar0->parent = bridge_pref`, the driver gets "not claimed; can't enable device" even though the hardware registers are correct. This single pointer is the difference between a working GPU and a doorstop.

Create the `Makefile`:

```makefile
obj-m += egpu_bar.o

KDIR := /lib/modules/$(shell uname -r)/build

all:
	make -C $(KDIR) M=$(PWD) modules

clean:
	make -C $(KDIR) M=$(PWD) clean
```

Build and install:

```bash
cd ~/egpu-bar-fix
make
sudo cp egpu_bar.ko /lib/modules/$(uname -r)/extra/
sudo depmod -a
```

## Step 4: Create the Boot Init Script

Create `/usr/local/bin/egpu-init.sh`:

```bash
#!/bin/bash
# eGPU BAR initialization for RX 6800 on Mac Mini 2018 (T2)
# Programs bridge pref windows + GPU BAR 0 to 64-bit space,
# loads kernel module to patch resource tree, then loads amdgpu.

LOG_TAG="egpu-init"
log() { logger -t "$LOG_TAG" "$1"; echo "$1"; }

log "=== eGPU Init Starting ==="

# Wait for Thunderbolt GPU to appear (up to 60 seconds)
GPU_BUS=""
for i in $(seq 1 30); do
    GPU_BUS=$(lspci -d 1002:73bf 2>/dev/null | head -1 | awk '{print $1}')
    [ -n "$GPU_BUS" ] && break
    sleep 2
done

if [ -z "$GPU_BUS" ]; then
    log "ERROR: RX 6800 not found after 60s"
    exit 1
fi
log "GPU found at $GPU_BUS"

# Walk the sysfs path to find all bridges from root to GPU
GPU_SYSFS=$(readlink -f /sys/bus/pci/devices/0000:$GPU_BUS 2>/dev/null)
if [ -z "$GPU_SYSFS" ]; then
    log "ERROR: Cannot resolve sysfs path for GPU"
    exit 1
fi

# Extract bridge BDFs from sysfs path (all PCI devices except the GPU itself)
BRIDGES=$(echo "$GPU_SYSFS" | tr '/' '\n' | grep '^0000:' | head -n-1 | sed 's/^0000://')
log "Bridge chain: $BRIDGES -> $GPU_BUS"

# Program all bridges with 64-bit pref window: 0x4010000000-0x401FFFFFFF
# Register 0x24 = Prefetchable Memory Base/Limit (bits 31:16 = limit, 15:0 = base)
# Register 0x28 = Prefetchable Base Upper 32 bits
# Register 0x2C = Prefetchable Limit Upper 32 bits
log "Programming bridge pref windows..."
for br in $BRIDGES; do
    CLASS=$(cat /sys/bus/pci/devices/0000:$br/class 2>/dev/null)
    if [ "${CLASS:0:6}" = "0x0604" ]; then
        setpci -s "$br" 24.L=1FF11001 2>/dev/null   # base=0x10010000, limit=0x1FF10000
        setpci -s "$br" 28.L=00000040 2>/dev/null   # upper base = 0x40
        setpci -s "$br" 2C.L=00000040 2>/dev/null   # upper limit = 0x40
        log "  $br: pref -> 0x4010000000-0x401FFFFFFF"
    fi
done

# Program GPU BAR 0 to 0x4010000000 (256MB, 64-bit prefetchable)
# Disable bus mastering + memory access during BAR programming
log "Programming GPU BAR 0..."
setpci -s "$GPU_BUS" COMMAND.W=0000          # disable everything
setpci -s "$GPU_BUS" 10.L=1000000C           # BAR 0 low: addr + 64-bit + prefetchable flags
setpci -s "$GPU_BUS" 14.L=00000040           # BAR 0 high: 0x40
setpci -s "$GPU_BUS" COMMAND.W=0007          # re-enable IO + Mem + BusMaster

BAR0_LO=$(setpci -s "$GPU_BUS" 10.L)
BAR0_HI=$(setpci -s "$GPU_BUS" 14.L)
log "BAR 0 programmed: low=$BAR0_LO high=$BAR0_HI"

# Load kernel module to patch resource tree
log "Loading egpu_bar module..."
modprobe egpu_bar 2>&1 || {
    insmod /lib/modules/$(uname -r)/extra/egpu_bar.ko 2>&1 || {
        log "ERROR: Failed to load egpu_bar"
        exit 1
    }
}

# Load amdgpu driver (blacklisted from auto-loading)
log "Loading amdgpu..."
modprobe amdgpu 2>&1
sleep 3

# Check result
if ls /dev/dri/card* >/dev/null 2>&1; then
    log "SUCCESS: eGPU initialized"
    ls -la /dev/dri/
else
    echo "0000:$GPU_BUS" > /sys/bus/pci/drivers/amdgpu/bind 2>/dev/null
    sleep 3
    if ls /dev/dri/card* >/dev/null 2>&1; then
        log "SUCCESS: eGPU initialized (manual bind)"
    else
        log "FAILED: No /dev/dri devices"
        dmesg | grep -i "amdgpu\|egpu_bar" | tail -10
    fi
fi
```

Make it executable:
```bash
sudo chmod +x /usr/local/bin/egpu-init.sh
```

## Step 5: Create the Systemd Service

Create `/etc/systemd/system/egpu-init.service`:

```ini
[Unit]
Description=Initialize eGPU BAR for RX 6800 on T2 Mac Mini
After=thunderbolt.service systemd-udevd.service
Wants=thunderbolt.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/egpu-init.sh
RemainAfterExit=yes
TimeoutStartSec=120

[Install]
WantedBy=multi-user.target
```

Enable it:
```bash
sudo systemctl daemon-reload
sudo systemctl enable egpu-init.service
```

## Step 6: Install Ollama with ROCm

```bash
curl -fsSL https://ollama.com/install.sh | sh
```

The installer auto-detects AMD GPUs and downloads ROCm libraries. For the RX 6800 (gfx1030), no additional configuration is needed.

**Important:** Ollama must start AFTER egpu-init completes, or it won't detect the GPU. Create a systemd drop-in:

```bash
sudo mkdir -p /etc/systemd/system/ollama.service.d
sudo tee /etc/systemd/system/ollama.service.d/egpu-dependency.conf << 'EOF'
[Unit]
After=egpu-init.service
Requires=egpu-init.service
EOF
sudo systemctl daemon-reload
```

## Step 7: Verify

Reboot and verify everything comes up automatically:

```bash
sudo reboot
```

After ~45 seconds, SSH back in and check:

```bash
# Kernel
uname -r                    # 7.0.9-1-t2-noble

# eGPU service
systemctl status egpu-init  # active (exited), SUCCESS

# GPU devices
ls /dev/dri/                # card0, renderD128

# VRAM
cat /sys/class/drm/card0/device/mem_info_vram_total   # 17163091968 (16GB)

# Ollama GPU detection
sudo journalctl -u ollama | grep gfx
# inference compute id=0 library=ROCm compute=gfx1030 name=ROCm0
# description="AMD Radeon RX 6800" total="16.0 GiB"

# Run inference
ollama run qwen3:8b 'Hello from the eGPU!'
ollama ps                   # Should show 100% GPU
```

## Boot Timeline

On a clean boot with all services configured:

| Time | Event |
|------|-------|
| t=0s | GRUB auto-selects T2 kernel (hidden menu, 5s timeout) |
| t=4s | egpu-init.service starts, waits for GPU on TB bus |
| t=12s | GPU found, bridges programmed, BAR set, module + amdgpu loaded |
| t=16s | egpu-init reports SUCCESS, /dev/dri/card0 exists |
| t=16s | ollama starts (depends on egpu-init), detects RX 6800 via ROCm |
| t=20s | SSH available |
| t=45s | Fully operational, ready for inference |

## Troubleshooting

### GPU not found after 60s
Check that the eGPU enclosure is powered on and the Thunderbolt cable is connected. Verify with `lspci | grep -i amd`.

### amdgpu kernel BUG (GART page table)
ReBAR is resizing BAR 0 to 16GB, overflowing bridge windows. Ensure `amdgpu.rebar=0` is in your GRUB config.

### Ollama shows 100% CPU
Race condition — ollama started before the GPU was ready. Verify the systemd drop-in exists at `/etc/systemd/system/ollama.service.d/egpu-dependency.conf`.

### Machine hangs at GRUB after crash
Missing `GRUB_RECORDFAIL_TIMEOUT`. Ubuntu's default is to wait forever after a failed boot. Set `GRUB_RECORDFAIL_TIMEOUT=5` in `/etc/default/grub`.

### SSH not available after reboot
If the machine is pingable but SSH is refused, it may be stuck at GRUB (recordfail) or a display manager is hanging. For headless operation, set `GRUB_TIMEOUT_STYLE=hidden`.

### NEVER do a full PCI rescan
`echo 1 > /sys/bus/pci/rescan` will crash the machine every time on this hardware. Don't do it.

## Architecture

```
Boot Flow:
  GRUB (T2 kernel + vfio-pci + pcie_aspm=off + rebar=0)
    → egpu-init.service
      → Wait for GPU on Thunderbolt bus (lspci poll)
      → setpci: Program 7 bridge pref windows (64-bit space)
      → setpci: Program GPU BAR 0 = 0x4010000000 (256MB)
      → insmod egpu_bar.ko: Patch kernel resource tree
      → modprobe amdgpu: Driver binds, 16GB VRAM initialized
    → ollama.service (After=egpu-init)
      → ROCm detects gfx1030, 16GB available
      → Ready for inference

Memory Map:
  0x4000000000-0x40000FFFFF  Intel HDA (do not use)
  0x4010000000-0x401FFFFFFF  RX 6800 BAR 0 (256MB) + bridge pref windows
  0x4020000000-0x7FFFFFFFFF  Available for second eGPU
```

## Files

| File | Purpose |
|------|---------|
| `egpu_bar.c` | Kernel module source — patches kernel resource tree |
| `Makefile` | Builds the kernel module |
| `egpu-init.sh` | Boot script — programs hardware + loads drivers |
| `egpu-init.service` | Systemd unit for egpu-init.sh |
| `amdgpu-egpu.conf` | Modprobe config — blacklists amdgpu, sets options |
| `ollama-egpu-dependency.conf` | Systemd drop-in — makes ollama wait for eGPU |
| `grub-default` | Reference copy of /etc/default/grub |

## License

MIT
