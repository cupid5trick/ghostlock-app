// SPDX-License-Identifier: GPL-2.0
// Minimal guest-side ION driver and DMA-BUF regression controller.
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>

#include "../../../tools/ion-kasan-test/ion_probe_uapi.h"

struct ion_allocation_data {
	uint64_t len;
	uint32_t heap_id_mask;
	uint32_t flags;
	uint32_t fd;
	uint32_t unused;
};

struct dma_buf_sync {
	uint64_t flags;
};

#define ION_IOC_MAGIC 'I'
#define ION_IOC_ALLOC _IOWR(ION_IOC_MAGIC, 0, struct ion_allocation_data)
#define DMA_BUF_IOCTL_SYNC _IOW('b', 0, struct dma_buf_sync)
#define DMA_BUF_SYNC_RW 3U
#define DMA_BUF_SYNC_END (1U << 2)

static int fail(const char *step)
{
	fprintf(stderr, "ION_TEST_FAIL step=%s errno=%d (%s)\n", step, errno,
		strerror(errno));
	return 1;
}

int main(void)
{
	struct ion_allocation_data allocation = {
		.len = 4096,
		.heap_id_mask = 1U << 0, /* ION_HEAP_TYPE_SYSTEM */
	};
	struct dma_buf_sync sync = { .flags = DMA_BUF_SYNC_RW | DMA_BUF_SYNC_END };
	int ion_fd;
	int probe_fd;
	int buf_fd;

	ion_fd = open("/dev/ion", O_RDWR | O_CLOEXEC);
	if (ion_fd < 0)
		return fail("open_real_dev_ion");
	if (ioctl(ion_fd, ION_IOC_ALLOC, &allocation) < 0)
		return fail("ION_IOC_ALLOC_system_heap");
	buf_fd = (int)allocation.fd;
	printf("ION_ALLOC_OK fd=%d len=%llu heap_mask=0x%x\n", buf_fd,
	       (unsigned long long)allocation.len, allocation.heap_id_mask);

	probe_fd = open("/dev/ion_kasan_probe", O_RDWR | O_CLOEXEC);
	if (probe_fd < 0)
		return fail("open_probe");
	if (ioctl(probe_fd, ION_PROBE_HOLD, &buf_fd) < 0)
		return fail("probe_hold_kmap");
	printf("ION_PROBE_HOLD_OK\n");

	if (ioctl(buf_fd, DMA_BUF_IOCTL_SYNC, &sync) < 0)
		return fail("DMA_BUF_SYNC_END");
	printf("ION_SYNC_END_OK\n");

	if (ioctl(probe_fd, ION_PROBE_TOUCH) < 0)
		return fail("probe_touch_after_sync_end");
	printf("ION_TEST_PASS mapping_survived_sync_end\n");

	if (ioctl(probe_fd, ION_PROBE_RELEASE) < 0)
		return fail("probe_release");
	close(probe_fd);
	close(buf_fd);
	close(ion_fd);
	return 0;
}
