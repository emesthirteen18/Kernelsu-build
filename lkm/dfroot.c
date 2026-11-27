#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/init.h>

static int __init dfroot_init(void)
{
	pr_info("dfroot: late-load handoff module loaded\n");
	return 0;
}

static void __exit dfroot_exit(void)
{
	pr_info("dfroot: unloaded\n");
}

module_init(dfroot_init);
module_exit(dfroot_exit);

MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("Device-matched DFRoot handoff module for Nothing Phone (4a) Pro");
MODULE_AUTHOR("DFRoot");
