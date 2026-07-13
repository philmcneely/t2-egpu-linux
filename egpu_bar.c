#include <linux/module.h>
#include <linux/pci.h>

#define GPU_VENDOR  0x1002
#define GPU_DEVICE  0x73bf
#define BRIDGE_DEV  0x1479

#define BAR0_ADDR   0x4010000000ULL
#define BAR0_SIZE   0x10000000ULL
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

	pref_idx = PCI_BRIDGE_RESOURCES + 2;
	bridge_pref = &bridge->resource[pref_idx];

	pr_info("egpu_bar: GPU at %s, bridge at %s\n",
		pci_name(gpu), pci_name(bridge));
	pr_info("egpu_bar: bridge pref before: %pR\n", bridge_pref);
	pr_info("egpu_bar: GPU BAR 0 before: %pR\n", &gpu->resource[0]);

	orig_bridge_start = bridge_pref->start;
	orig_bridge_end = bridge_pref->end;
	orig_bridge_flags = bridge_pref->flags;

	if (bridge_pref->parent)
		release_resource(bridge_pref);

	bridge_pref->start = PREF_START;
	bridge_pref->end = PREF_END;
	bridge_pref->flags = IORESOURCE_MEM | IORESOURCE_PREFETCH |
			     IORESOURCE_MEM_64;

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
