// SPDX-License-Identifier: GPL-2.0
#include <linux/dma-buf.h>
#include <linux/fs.h>
#include <linux/miscdevice.h>
#include <linux/module.h>
#include <linux/mutex.h>
#include <linux/uaccess.h>

#include "ion_probe_uapi.h"

static DEFINE_MUTEX(probe_lock);
static struct dma_buf *held_buf;
static void *held_mapping;

static long ion_probe_ioctl(struct file *file, unsigned int cmd,
			    unsigned long arg)
{
	struct dma_buf *buf;
	int fd;
	int ret = 0;
	u8 value;

	(void)file;
	mutex_lock(&probe_lock);
	switch (cmd) {
	case ION_PROBE_HOLD:
		if (held_buf) {
			ret = -EBUSY;
			break;
		}
		if (copy_from_user(&fd, (void __user *)arg, sizeof(fd))) {
			ret = -EFAULT;
			break;
		}
		buf = dma_buf_get(fd);
		if (IS_ERR(buf)) {
			ret = PTR_ERR(buf);
			break;
		}
		ret = dma_buf_begin_cpu_access(buf, DMA_BIDIRECTIONAL);
		if (ret) {
			dma_buf_put(buf);
			break;
		}
		held_mapping = dma_buf_kmap(buf, 0);
		if (IS_ERR_OR_NULL(held_mapping)) {
			ret = held_mapping ? PTR_ERR(held_mapping) : -ENOMEM;
			dma_buf_put(buf);
			held_mapping = NULL;
			break;
		}
		held_buf = buf;
		pr_info("ION_PROBE_HELD fd=%d mapping=%p\n", fd, held_mapping);
		break;
	case ION_PROBE_TOUCH:
		if (!held_buf || !held_mapping) {
			ret = -ENXIO;
			break;
		}
		value = READ_ONCE(*(u8 *)held_mapping);
		WRITE_ONCE(*(u8 *)held_mapping, value ^ 0x5a);
		pr_info("ION_PROBE_TOUCH_OK value=%02x\n", value);
		break;
	case ION_PROBE_RELEASE:
		if (!held_buf)
			break;
		dma_buf_kunmap(held_buf, 0, held_mapping);
		dma_buf_put(held_buf);
		held_buf = NULL;
		held_mapping = NULL;
		pr_info("ION_PROBE_RELEASED\n");
		break;
	default:
		ret = -ENOTTY;
	}
	mutex_unlock(&probe_lock);
	return ret;
}

static const struct file_operations ion_probe_fops = {
	.owner = THIS_MODULE,
	.unlocked_ioctl = ion_probe_ioctl,
#ifdef CONFIG_COMPAT
	.compat_ioctl = ion_probe_ioctl,
#endif
};

static struct miscdevice ion_probe_device = {
	.minor = MISC_DYNAMIC_MINOR,
	.name = "ion_kasan_probe",
	.fops = &ion_probe_fops,
};

static int __init ion_probe_init(void)
{
	return misc_register(&ion_probe_device);
}

static void __exit ion_probe_exit(void)
{
	if (held_buf) {
		dma_buf_kunmap(held_buf, 0, held_mapping);
		dma_buf_put(held_buf);
	}
	misc_deregister(&ion_probe_device);
}

module_init(ion_probe_init);
module_exit(ion_probe_exit);
MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("ION DMA-BUF mapping lifetime regression probe");
