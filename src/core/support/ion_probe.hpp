#ifndef GHOSTLOCK_SUPPORT_ION_PROBE_HPP
#define GHOSTLOCK_SUPPORT_ION_PROBE_HPP

#include <cstdint>
#include <string>

namespace ghostlock::support::ion_probe {

enum class PathStatus { Present, Absent, Unknown };
enum class PermissionStatus { Allowed, Denied, Unknown, NotTested };
enum class OpenStatus { Opened, Denied, Failed, NotTested };
enum class IoctlStatus { Supported, Unsupported, Denied, Failed, NotTested };

struct Result {
    PathStatus path{PathStatus::Unknown};
    PermissionStatus read_permission{PermissionStatus::NotTested};
    OpenStatus open{OpenStatus::NotTested};
    IoctlStatus heap_query{IoctlStatus::NotTested};
    int64_t heap_count{-1};
};

/* Narrow syscall seam: production uses /dev/ion; host tests inject outcomes. */
struct Syscalls {
    int (*stat_node)(bool *is_character_device);
    int (*check_read_permission)();
    int (*open_read_only)();
    int (*query_heap_count)(int fd, uint32_t *heap_count);
    int (*close_fd)(int fd);
};

Result probe(const Syscalls &syscalls);
Result probe();
std::string format(const Result &result);
int run_cli();

} // namespace ghostlock::support::ion_probe

#endif
