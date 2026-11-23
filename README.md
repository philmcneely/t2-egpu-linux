# RX 6800 eGPU on Mac Mini 2018 (T2) — Linux Setup Guide

Running an AMD RX 6800 over Thunderbolt 3 on a Mac Mini 2018 with Ubuntu Linux for LLM inference. This guide covers the full stack: kernel parameters, PCIe BAR programming, a custom kernel module, automated boot, and Ollama with ROCm.

## Hardware

- **Mac Mini 2018** (Macmini8,1) with T2 security chip
- **AMD Radeon RX 6800** (Navi 21, gfx1030) — NOT the XT
- **AKiTiO Node Titan** Thunderbolt 3 eGPU enclosure
- **Ubuntu 24.04** with [T2 Linux kernel](https://github.com/t2linux/linux-t2-patches) (7.0.9-1-t2-noble)

This page walks through the single-card setup. Two more setups live in their own folders:

- [`dual-gpu/`](dual-gpu/): two RX 6800s, one per Thunderbolt controller, on the same Mac Mini. Each card gets a 512 MB window that maps both BAR 0 and the doorbell BAR 2. This is the version running in production.
- [`radeon-vii/`](radeon-vii/): two Radeon VIIs (Vega 20) on a second Mac Mini 2018.

## The Problem

The T2 Mac Mini's firmware allocates only 224MB of prefetchable memory for the entire Thunderbolt domain. The RX 6800's BAR 0 needs at minimum 256MB. The GPU shows up in `lspci` but the amdgpu driver can't enable it — the kernel's PCIe resource tree doesn't have a valid memory window.

On top of that, the kernel caches bridge resources during initial PCI scan and never updates them. Even if you reprogram the hardware registers with `setpci`, the kernel's internal `struct resource` still reflects the original (broken) values. The amdgpu driver checks the kernel's resource tree, not the hardware registers, so it refuses to enable the device.

The solution is a three-layer approach:
1. **setpci** — Program the hardware registers (bridge pref windows + GPU BAR 0)
2. **Kernel module** — Patch the kernel's internal resource tree to match
3. **Systemd service** — Automate everything on boot

### Why the BAR goes above 4 GiB

The firmware's prefetchable window sits below 4 GiB and is 224 MB. Navi 21's smallest BAR 0 is 256 MB, so the card cannot fit there whatever you resize it to. This guide places the window in the host bridge's 64-bit space at `0x4010000000` instead. On the Mac Mini 2018 that works. Both RX 6800s on the dual-card box run inference around the clock with their framebuffer and doorbell BARs above 4 GiB.

Other T2 Macs behave differently. On a MacBookPro16,1, Antonio Telesca found that the T2 hard-hangs the machine on any eGPU memory access above 4 GiB. For NVIDIA cards he shrinks BAR 1 to 64 MiB with Resizable BAR so every BAR fits below 4 GiB: [TelescaAntonio/t2-egpu-nvidia](https://github.com/TelescaAntonio/t2-egpu-nvidia). See also [t2linux issue #189](https://github.com/t2linux/T2-Debian-and-Ubuntu-Kernel/issues/189). If you have an NVIDIA card, or a MacBook where the above-4 GiB window hangs, start there. Its rescan step would not help an RX 6800 anyway. After a rescan the kernel places BARs inside the firmware's window, and a 256 MB BAR 0 does not fit in 224 MB.

## Prerequisites

Install the T2 Linux kernel from [t2linux.org](https://wiki.t2linux.org). The generic Ubuntu kernel may work for basic functionality but the T2 kernel includes drivers for the Mac's keyboard, trackpad, and other T2-specific hardware.

```bash
# Verify you're on the T2 kernel
uname -r
# Should show something like: 7.0.9-1-t2-noble
```

This setup was built and tested on 7.0.9-1-t2-noble. The kernel module is built against one kernel, so rebuild and reinstall it after every kernel update (Step 3), or `egpu-init` will fail to load `egpu_bar` and stop before loading amdgpu.

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

`pci=realloc` is part of the single-card configuration this guide was built and tested with. Whether a single card needs it has not been tested. **With two eGPUs, leave it out.** On the dual RX 6800 Mac Mini it broke the whole BAR tree and took down the working card too. The dual-card setups in [`dual-gpu/`](dual-gpu/) and [`radeon-vii/`](radeon-vii/) boot without it.

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
| `pci=realloc` | Lets the kernel reallocate PCI resources. Single card only: drop it with two eGPUs (see above) |
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

## Step 4: Install the Boot Init Script

Install [`egpu-init.sh`](egpu-init.sh) from this repo:

```bash
sudo install -m 755 egpu-init.sh /usr/local/bin/egpu-init.sh
```

At boot it:

1. Waits up to 60 seconds for the RX 6800 (`1002:73bf`) to appear on the Thunderbolt bus.
2. Walks the PCI path from the root port to the GPU and programs every bridge's prefetchable window to `0x4010000000-0x401FFFFFFF` (registers `0x24`, `0x28`, `0x2C`).
3. Turns off the GPU's memory decode, sets BAR 0 to `0x4010000000` (registers `0x10`, `0x14`), then turns decode back on.
4. Loads `egpu_bar` to patch the kernel's resource tree, then loads amdgpu.

It fails closed. A bad step stops before anything touches the GPU:

- **Every register is read back.** If any bridge window or BAR 0 does not read back as written, memory decode stays off, nothing is loaded, and the log names the register with the value it expected and the value it got.
- **A card amdgpu already drives is left alone.** Rewriting BARs under a live driver hangs the machine. This matters when the script is re-run to recover a card: unbind amdgpu first.
- **The GPU's HDMI audio function (`.1`) is unbound and kept unbound.** The machine is headless with `amdgpu.dc=0`, so it has no use.
- **No eGPU attached is not an error.** The script logs it and exits 0, so the machine boots normally without the enclosure.

Exit codes: `0` card up or no eGPU attached, `1` card found but not brought up, `3` verify-only mismatch.

To check a running machine without changing anything, run it in verify-only mode. It reads every register and compares it with what the script would write:

```bash
sudo EGPU_VERIFY_ONLY=1 /usr/local/bin/egpu-init.sh
# VERIFY: bridges + BAR 0 match
```

The tests in [`tests/`](tests/) run both scripts against a fake `/sys` with stand-ins for `setpci`, `lspci` and `modprobe`, in an Ubuntu container: `tests/run.sh`.

## Step 5: Create the Systemd Service

Install [`egpu-init.service`](egpu-init.service):

```bash
sudo cp egpu-init.service /etc/systemd/system/egpu-init.service
sudo systemctl daemon-reload
sudo systemctl enable egpu-init.service
```

```ini
[Unit]
Description=Initialize eGPU BAR for RX 6800 on T2 Mac Mini
After=thunderbolt.service systemd-udevd.service
Wants=thunderbolt.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/egpu-init.sh
RemainAfterExit=yes
TimeoutStartSec=infinity

[Install]
WantedBy=multi-user.target
```

`TimeoutStartSec=infinity` is deliberate. On a cold boot a Thunderbolt enclosure can take minutes to authorize, and a finite timeout (earlier versions used 120 s) lets systemd kill the script before the card appears, so the machine boots with no GPU. The script bounds its own wait.

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
sudo EGPU_VERIFY_ONLY=1 /usr/local/bin/egpu-init.sh   # VERIFY: bridges + BAR 0 match

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

### "no eGPU attached" in the egpu-init log
The card did not appear on the bus within 60 seconds. Check that the enclosure is powered on, the Thunderbolt cable is connected, and the enclosure is enrolled (`boltctl enroll --policy auto <uuid>`, not just authorized). Verify with `lspci -d 1002:73bf`.

### "registers did not read back" in the egpu-init log
A bridge or the GPU ignored a write. The log line names each register with the value it wanted and the value it got. The script left the card's memory decode off and loaded nothing, so the machine is safe. Usual causes: the card moved to a different bus (new port or cable; reboot), or a bridge in the chain has no 64-bit prefetchable window, in which case the above-4 GiB placement cannot work on that topology.

### "already bound" in the egpu-init log
amdgpu already drives the card, so the script did not reprogram it. To re-run the setup on a live machine, stop anything using the GPU, unbind it (`echo 0000:<bus> | sudo tee /sys/bus/pci/drivers/amdgpu/unbind`), `sudo rmmod egpu_bar`, then run `egpu-init.sh` again.

### amdgpu kernel BUG (GART page table)
ReBAR is resizing BAR 0 to 16GB, overflowing bridge windows. Ensure `amdgpu.rebar=0` is in your GRUB config.

### Ollama shows 100% CPU
Race condition — ollama started before the GPU was ready. Verify the systemd drop-in exists at `/etc/systemd/system/ollama.service.d/egpu-dependency.conf`.

### Machine hangs at GRUB after crash
Missing `GRUB_RECORDFAIL_TIMEOUT`. Ubuntu's default is to wait forever after a failed boot. Set `GRUB_RECORDFAIL_TIMEOUT=5` in `/etc/default/grub`.

### SSH not available after reboot
If the machine is pingable but SSH is refused, it may be stuck at GRUB (recordfail) or a display manager is hanging. For headless operation, set `GRUB_TIMEOUT_STYLE=hidden`.

### NEVER do a full PCI rescan on a running machine
`echo 1 > /sys/bus/pci/rescan` crashed a Mac Pro 2013 (Thunderbolt 2) every time ([write-up](mac-pro-2013-tb2-failure.md)). It also crashed the dual-card Mac Mini once, when it ran on a live system: one card bound to amdgpu behind the hand-programmed window, the second enclosure absent. Don't run it on a machine with a card up.

The [NVIDIA method](https://github.com/TelescaAntonio/t2-egpu-nvidia) does rescan on a MacBookPro16,1, but under different conditions. Its script runs at boot before any GPU driver is loaded, turns off driver autoprobe, and removes the eGPU's bridge subtree first. The rescan then rebuilds only that subtree, with no driver behind it. That sequence has not been tried on the Mac Mini.

### Second eGPU appears "missing" right after a cold boot
On a dual-eGPU box the second card (on the slower/farther TB controller) can take a minute or two
longer to enumerate than the first, up to about 190 seconds on a cold boot. The
[`dual-gpu/`](dual-gpu/) script waits up to 300 seconds for both cards before it programs anything,
and its service must use `TimeoutStartSec=infinity` so systemd does not kill it first. **Wait a few
minutes and re-check before concluding a card is dead.** Prefer a clean `poweroff` + Wake-on-LAN over a cold power-cycle, and
resist reboot-looping to "get both faster" — repeated reboots can glitch the GPU SMU
(`smu_v11_0_i2c_xfer ... NAK` in dmesg) and cause more trouble than the late card ever would.

## Architecture

```
Boot Flow:
  GRUB (T2 kernel + vfio-pci + pcie_aspm=off + rebar=0)
    → egpu-init.service
      → Wait for GPU on Thunderbolt bus (lspci poll)
      → setpci: Program 7 bridge pref windows (64-bit space)
      → setpci: Program GPU BAR 0 = 0x4010000000 (256MB)
      → read back every register; any mismatch: decode off, stop
      → unbind the GPU's HDMI audio function
      → insmod egpu_bar.ko: Patch kernel resource tree
      → modprobe amdgpu: Driver binds, 16GB VRAM initialized
    → ollama.service (After=egpu-init)
      → ROCm detects gfx1030, 16GB available
      → Ready for inference

Memory Map:
  0x4000000000-0x40000FFFFF  Intel HDA (do not use)
  0x4010000000-0x401FFFFFFF  RX 6800 BAR 0 (256MB) + bridge pref windows
  0x4020000000-0x7FFFFFFFFF  Available (dual-gpu/ uses 512MB per card: 0x4010000000, 0x4030000000)
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
| `tests/` | Tests for both init scripts against a fake `/sys` (`tests/run.sh`, needs Docker) |
| `dual-gpu/` | Two RX 6800s: 512MB window per card, BAR 0 + doorbell BAR 2 |
| `radeon-vii/` | Two Radeon VIIs (Vega 20) |

## License

MIT
