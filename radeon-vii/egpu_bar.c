#include <linux/module.h>
#include <linux/pci.h>

#define GPU_VENDOR  0x1002
#define GPU_DEVICE  0x66af      /* Radeon VII (Vega 20) */

/* Each VII gets a 512MB 64-bit prefetchable window:
 *   card i base = WIN_BASE + i*WIN_STRIDE
 *   BAR0 (256MB framebuffer) at base + BAR0_OFF
 *   BAR2 (2MB  doorbell)     at base + BAR2_OFF   <-- required for KIQ compute ring
 * Must match the setpci programming in egpu-init.sh.
 */
#define WIN_BASE    0x4010000000ULL
#define WIN_STRIDE  0x20000000ULL   /* 512MB per card */
#define BAR0_OFF    0x00000000ULL
#define BAR0_SIZE   0x10000000ULL   /* 256MB */
#define BAR2_OFF    0x10000000ULL
#define BAR2_SIZE   0x00200000ULL   /* 2MB */
#define MAX_GPUS    4

struct egpu_saved {
	struct pci_dev *bridge;
	struct pci_dev *gpu;
	resource_size_t bridge_start;
	resource_size_t bridge_end;
	unsigned long bridge_flags;
};

static struct egpu_saved saved[MAX_GPUS];
static int saved_count;

static int __init egpu_bar_init(void)
{
	struct pci_dev *gpu = NULL;
	int i = 0;

	while ((gpu = pci_get_device(GPU_VENDOR, GPU_DEVICE, gpu)) != NULL) {
		struct pci_dev *bridge;
		struct resource *bridge_pref, *bar0, *bar2;
		u64 base;
		int pref_idx;

		if (i >= MAX_GPUS) {
			pr_warn("egpu_bar: >%d GPUs, ignoring rest\n", MAX_GPUS);
			pci_dev_put(gpu);
			break;
		}

		bridge = pci_upstream_bridge(gpu);
		if (!bridge) {
			pr_err("egpu_bar: no upstream bridge for %s\n", pci_name(gpu));
			continue;
		}

		base = WIN_BASE + (u64)i * WIN_STRIDE;
		pref_idx = PCI_BRIDGE_RESOURCES + 2;
		bridge_pref = &bridge->resource[pref_idx];

		pr_info("egpu_bar: [%d] GPU %s bridge %s window 0x%llx (512M)\n",
			i, pci_name(gpu), pci_name(bridge), base);
		pr_info("egpu_bar: [%d] BAR0 before %pR / BAR2 before %pR\n",
			i, &gpu->resource[0], &gpu->resource[2]);

		saved[i].bridge_start = bridge_pref->start;
		saved[i].bridge_end   = bridge_pref->end;
		saved[i].bridge_flags = bridge_pref->flags;
		if (bridge_pref->parent)
			release_resource(bridge_pref);

		/* Widen bridge pref window to cover BAR0 + BAR2 (whole 512M stride) */
		bridge_pref->start = base;
		bridge_pref->end   = base + WIN_STRIDE - 1;
		bridge_pref->flags = IORESOURCE_MEM | IORESOURCE_PREFETCH |
				     IORESOURCE_MEM_64;

		/* BAR0 - framebuffer aperture (256MB) */
		bar0 = &gpu->resource[0];
		bar0->start = base + BAR0_OFF;
		bar0->end   = base + BAR0_OFF + BAR0_SIZE - 1;
		bar0->flags = IORESOURCE_MEM | IORESOURCE_PREFETCH |
			      IORESOURCE_MEM_64 | IORESOURCE_SIZEALIGN;
		bar0->parent = bridge_pref;

		/* BAR2 - doorbell aperture (2MB); without this the KIQ compute
		 * ring test times out (-110) because the GPU never sees ring
		 * doorbells. This is the key difference from the Navi setup. */
		bar2 = &gpu->resource[2];
		bar2->start = base + BAR2_OFF;
		bar2->end   = base + BAR2_OFF + BAR2_SIZE - 1;
		bar2->flags = IORESOURCE_MEM | IORESOURCE_PREFETCH |
			      IORESOURCE_MEM_64 | IORESOURCE_SIZEALIGN;
		bar2->parent = bridge_pref;

		pr_info("egpu_bar: [%d] BAR0 after %pR\n", i, bar0);
		pr_info("egpu_bar: [%d] BAR2 after %pR (parent=%pR)\n",
			i, bar2, bar2->parent);

		saved[i].bridge = bridge;
		saved[i].gpu = gpu;
		pci_dev_get(bridge);
		pci_dev_get(gpu);
		i++;
	}

	saved_count = i;
	if (saved_count == 0) {
		pr_err("egpu_bar: no Radeon VII (1002:66af) found\n");
		return -ENODEV;
	}
	pr_info("egpu_bar: patched %d GPU(s) incl doorbell BAR2\n", saved_count);
	return 0;
}

static void __exit egpu_bar_exit(void)
{
	int i, pref_idx = PCI_BRIDGE_RESOURCES + 2;

	for (i = 0; i < saved_count; i++) {
		if (saved[i].gpu) {
			int b;
			for (b = 0; b <= 2; b += 2) {
				saved[i].gpu->resource[b].parent = NULL;
				saved[i].gpu->resource[b].start = 0;
				saved[i].gpu->resource[b].end = 0;
				saved[i].gpu->resource[b].flags = 0;
			}
			pci_dev_put(saved[i].gpu);
		}
		if (saved[i].bridge) {
			struct resource *bp = &saved[i].bridge->resource[pref_idx];
			bp->start = saved[i].bridge_start;
			bp->end = saved[i].bridge_end;
			bp->flags = saved[i].bridge_flags;
			pci_dev_put(saved[i].bridge);
		}
	}
	pr_info("egpu_bar: unloaded, resources restored\n");
}

module_init(egpu_bar_init);
module_exit(egpu_bar_exit);
MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("Fix eGPU BAR0 + doorbell BAR2 for Radeon VII on T2 Mac Mini");
MODULE_AUTHOR("Phil McNeely");
