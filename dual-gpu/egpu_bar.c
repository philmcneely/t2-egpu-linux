#include <linux/module.h>
#include <linux/pci.h>

#define GPU_VENDOR  0x1002
#define GPU_DEVICE  0x73bf
#define BRIDGE_DEV  0x1479

/* Each RX 6800 needs a 256MB (0x10000000) 64-bit prefetchable BAR 0.
 * Card i is placed at BASE + i * STRIDE. The T2 firmware under-allocates
 * these windows (224MB) and the addresses collide with each other, so we
 * assign each card its own non-overlapping window in unused 64-bit space:
 *   card 0 -> 0x4010000000 - 0x401FFFFFFF
 *   card 1 -> 0x4020000000 - 0x402FFFFFFF
 * This must match the setpci window programming in egpu-init.sh.
 */
#define BAR0_BASE   0x4010000000ULL
#define BAR0_SIZE   0x10000000ULL
#define BAR0_STRIDE 0x10000000ULL
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
		struct resource *bridge_pref, *bar0;
		u64 base;
		int pref_idx;

		if (i >= MAX_GPUS) {
			pr_warn("egpu_bar: more than %d GPUs, ignoring the rest\n",
				MAX_GPUS);
			pci_dev_put(gpu);
			break;
		}

		bridge = pci_upstream_bridge(gpu);
		if (!bridge) {
			pr_err("egpu_bar: no upstream bridge for GPU %s\n",
			       pci_name(gpu));
			continue;
		}

		base = BAR0_BASE + (u64)i * BAR0_STRIDE;
		pref_idx = PCI_BRIDGE_RESOURCES + 2;
		bridge_pref = &bridge->resource[pref_idx];

		pr_info("egpu_bar: [%d] GPU %s, bridge %s, window 0x%llx\n",
			i, pci_name(gpu), pci_name(bridge), base);
		pr_info("egpu_bar: [%d] bridge pref before: %pR\n", i, bridge_pref);
		pr_info("egpu_bar: [%d] GPU BAR 0 before: %pR\n", i, &gpu->resource[0]);

		saved[i].bridge_start = bridge_pref->start;
		saved[i].bridge_end = bridge_pref->end;
		saved[i].bridge_flags = bridge_pref->flags;

		if (bridge_pref->parent)
			release_resource(bridge_pref);

		bridge_pref->start = base;
		bridge_pref->end = base + BAR0_SIZE - 1;
		bridge_pref->flags = IORESOURCE_MEM | IORESOURCE_PREFETCH |
				     IORESOURCE_MEM_64;

		bar0 = &gpu->resource[0];
		bar0->start = base;
		bar0->end = base + BAR0_SIZE - 1;
		bar0->flags = IORESOURCE_MEM | IORESOURCE_PREFETCH |
			      IORESOURCE_MEM_64 | IORESOURCE_SIZEALIGN;
		bar0->parent = bridge_pref;

		pr_info("egpu_bar: [%d] bridge pref after: %pR\n", i, bridge_pref);
		pr_info("egpu_bar: [%d] GPU BAR 0 after: %pR (parent=%pR)\n",
			i, bar0, bar0->parent);

		saved[i].bridge = bridge;
		saved[i].gpu = gpu;
		pci_dev_get(bridge);
		pci_dev_get(gpu);   /* hold our own ref; loop's put balances the get */
		i++;
	}

	saved_count = i;
	if (saved_count == 0) {
		pr_err("egpu_bar: no RX 6800 found\n");
		return -ENODEV;
	}

	pr_info("egpu_bar: patched %d GPU(s)\n", saved_count);
	return 0;
}

static void __exit egpu_bar_exit(void)
{
	int i, pref_idx = PCI_BRIDGE_RESOURCES + 2;

	for (i = 0; i < saved_count; i++) {
		if (saved[i].gpu) {
			saved[i].gpu->resource[0].parent = NULL;
			saved[i].gpu->resource[0].start = 0;
			saved[i].gpu->resource[0].end = 0;
			saved[i].gpu->resource[0].flags = 0;
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
MODULE_DESCRIPTION("Fix eGPU BAR 0 resource for T2 Mac Mini (multi-GPU)");
MODULE_AUTHOR("Phil McNeely");
