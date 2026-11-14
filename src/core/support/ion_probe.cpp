#include "support/ion_probe.hpp"

#include <cerrno>
#include <cstdio>
#include <fcntl.h>
#include <linux/ioctl.h>
#include <string_view>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <unistd.h>

namespace ghostlock::support::ion_probe {
namespace {

constexpr char kIonDevicePath[] = "/dev/ion";

/* Minimal Android ION UAPI shape: drivers/staging/android/uapi/ion.h. */
struct IonHeapQuery {
    uint32_t count;
    uint32_t reserved0;
    uint64_t heaps;
    uint32_t reserved1;
    uint32_t reserved2;
};

static_assert(sizeof(IonHeapQuery) == 24);
constexpr unsigned long kIonIoctlHeapQuery = _IOWR('I', 8, IonHeapQuery);

int stat_node(bool *is_character_device) {
    struct stat info {};
    if (::stat(kIonDevicePath, &info) != 0) return -1;
    *is_character_device = S_ISCHR(info.st_mode);
    return 0;
}

int check_read_permission() {
    return ::access(kIonDevicePath, R_OK);
}

int open_read_only() {
    return ::open(kIonDevicePath, O_RDONLY | O_CLOEXEC);
}

int query_heap_count(int fd, uint32_t *heap_count) {
    IonHeapQuery query{};
    /* A null heap buffer requests only the count; this does not allocate an ION buffer. */
    if (::ioctl(fd, kIonIoctlHeapQuery, &query) != 0) return -1;
    *heap_count = query.count;
    return 0;
}

int close_fd(int fd) {
    return ::close(fd);
}

const Syscalls kRealSyscalls{
    stat_node,
    check_read_permission,
    open_read_only,
    query_heap_count,
    close_fd,
};

bool is_permission_error(int error) {
    return error == EACCES || error == EPERM;
}

std::string_view name(PathStatus status) {
    switch (status) {
        case PathStatus::Present: return "PRESENT";
        case PathStatus::Absent: return "ABSENT";
        case PathStatus::Unknown: return "UNKNOWN";
    }
    return "UNKNOWN";
}

std::string_view name(PermissionStatus status) {
    switch (status) {
        case PermissionStatus::Allowed: return "ALLOWED";
        case PermissionStatus::Denied: return "DENIED";
        case PermissionStatus::Unknown: return "UNKNOWN";
        case PermissionStatus::NotTested: return "NOT_TESTED";
    }
    return "UNKNOWN";
}

std::string_view name(OpenStatus status) {
    switch (status) {
        case OpenStatus::Opened: return "OPENED";
        case OpenStatus::Denied: return "DENIED";
        case OpenStatus::Failed: return "FAILED";
        case OpenStatus::NotTested: return "NOT_TESTED";
    }
    return "FAILED";
}

std::string_view name(IoctlStatus status) {
    switch (status) {
        case IoctlStatus::Supported: return "SUPPORTED";
        case IoctlStatus::Unsupported: return "UNSUPPORTED";
        case IoctlStatus::Denied: return "DENIED";
        case IoctlStatus::Failed: return "FAILED";
        case IoctlStatus::NotTested: return "NOT_TESTED";
    }
    return "FAILED";
}

} // namespace

Result probe(const Syscalls &syscalls) {
    Result result;
    bool is_character_device = false;
    if (syscalls.stat_node(&is_character_device) != 0) {
        result.path = (errno == ENOENT || errno == ENOTDIR) ? PathStatus::Absent : PathStatus::Unknown;
        return result;
    }
    if (!is_character_device) return result;
    result.path = PathStatus::Present;

    if (syscalls.check_read_permission() == 0) {
        result.read_permission = PermissionStatus::Allowed;
    } else {
        result.read_permission = is_permission_error(errno) ? PermissionStatus::Denied
                                                             : PermissionStatus::Unknown;
    }

    const int fd = syscalls.open_read_only();
    if (fd < 0) {
        result.open = is_permission_error(errno) ? OpenStatus::Denied : OpenStatus::Failed;
        return result;
    }
    result.open = OpenStatus::Opened;

    uint32_t heap_count = 0;
    if (syscalls.query_heap_count(fd, &heap_count) == 0) {
        result.heap_query = IoctlStatus::Supported;
        result.heap_count = static_cast<int64_t>(heap_count);
    } else if (is_permission_error(errno)) {
        result.heap_query = IoctlStatus::Denied;
    } else if (errno == ENOTTY || errno == EOPNOTSUPP) {
        result.heap_query = IoctlStatus::Unsupported;
    } else {
        result.heap_query = IoctlStatus::Failed;
    }
    (void)syscalls.close_fd(fd);
    return result;
}

Result probe() {
    return probe(kRealSyscalls);
}

std::string format(const Result &result) {
    const std::string count = result.heap_query == IoctlStatus::Supported
                                  ? std::to_string(result.heap_count)
                                  : "-";
    return "ION_PROBE\t" + std::string(name(result.path)) + "\t" +
           std::string(name(result.read_permission)) + "\t" + std::string(name(result.open)) + "\t" +
           std::string(name(result.heap_query)) + "\t" + count;
}

int run_cli() {
    const std::string output = format(probe());
    (void)std::printf("%s\n", output.c_str());
    return 0;
}

} // namespace ghostlock::support::ion_probe
