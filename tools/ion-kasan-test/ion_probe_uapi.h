#ifndef GHOSTLOCK_ION_PROBE_UAPI_H
#define GHOSTLOCK_ION_PROBE_UAPI_H

#ifdef __KERNEL__
#include <linux/ioctl.h>
#else
#include <sys/ioctl.h>
#endif

#define ION_PROBE_IOC_MAGIC 'K'
#define ION_PROBE_HOLD _IOW(ION_PROBE_IOC_MAGIC, 0, int)
#define ION_PROBE_TOUCH _IO(ION_PROBE_IOC_MAGIC, 1)
#define ION_PROBE_RELEASE _IO(ION_PROBE_IOC_MAGIC, 2)

#endif
