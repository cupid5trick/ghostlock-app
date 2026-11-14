// SPDX-License-Identifier: GPL-2.0
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <linux/reboot.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/mount.h>
#include <sys/reboot.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

static int run_demo(void)
{
	pid_t child = fork();
	int status;

	if (child < 0)
		return -1;
	if (!child) {
		execl("/ion_backend_demo", "ion_backend_demo", (char *)NULL);
		perror("exec ion_backend_demo");
		_exit(127);
	}
	if (waitpid(child, &status, 0) < 0)
		return -1;
	if (!WIFEXITED(status) || WEXITSTATUS(status) != 0)
		return -1;
	return 0;
}

int main(void)
{
	int fd;
	int status = 1;

	setvbuf(stdout, NULL, _IONBF, 0);
	(void)mkdir("/dev", 0755);
	(void)mkdir("/proc", 0555);
	(void)mkdir("/sys", 0555);
	if (mount("devtmpfs", "/dev", "devtmpfs", 0, "mode=0755") < 0 &&
	    errno != EBUSY) {
		perror("mount devtmpfs");
		goto out;
	}
	if (mount("proc", "/proc", "proc", 0, NULL) < 0)
		perror("mount proc");
	if (mount("sysfs", "/sys", "sysfs", 0, NULL) < 0)
		perror("mount sysfs");
	{
		FILE *module = fopen("/ion_kasan_probe.ko", "rb");
		long size;
		void *image;
		struct stat st;

		if (!module) {
			perror("open probe module");
			goto out;
		}
		if (fstat(fileno(module), &st) < 0 || st.st_size <= 0) {
			perror("stat probe module");
			fclose(module);
			goto out;
		}
		size = st.st_size;
		image = malloc((size_t)size);
		if (!image || fread(image, 1, (size_t)size, module) != (size_t)size) {
			perror("read probe module");
			free(image);
			fclose(module);
			goto out;
		}
		fclose(module);
		if (syscall(__NR_init_module, image, (unsigned long)size, "") < 0) {
			perror("init_module ion_kasan_probe");
			free(image);
			goto out;
		}
		free(image);
	}
	fd = open("/dev/ion", O_RDWR | O_CLOEXEC);
	if (fd < 0) {
		perror("open /dev/ion from registered driver");
		goto out;
	}
	close(fd);
	puts("ION_DRIVER_READY real_misc_device=/dev/ion");
	if (run_demo() < 0) {
		puts("ION_GUEST_FAIL demo_or_mapping_probe");
		goto out;
	}
	puts("ION_GUEST_PASS");
	status = 0;
out:
	if (status)
		puts("ION_GUEST_EXIT_FAILURE");
	sync();
	reboot(status ? LINUX_REBOOT_CMD_RESTART : LINUX_REBOOT_CMD_POWER_OFF);
	for (;;)
		pause();
}
