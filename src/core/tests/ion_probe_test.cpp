#include "support/ion_probe.hpp"

#include <cassert>
#include <cerrno>
#include <cstdint>
#include <cstdio>
#include <string>

using namespace ghostlock::support::ion_probe;

namespace {

struct Script {
    int stat_result{0};
    int stat_error{0};
    bool character_device{true};
    int permission_result{0};
    int permission_error{0};
    int fd{17};
    int open_error{0};
    int query_result{0};
    int query_error{0};
    uint32_t heaps{3};
    int close_count{0};
    int open_count{0};
    int query_count{0};
} script;

int fake_stat(bool *is_character_device) {
    if (script.stat_result != 0) {
        errno = script.stat_error;
        return -1;
    }
    *is_character_device = script.character_device;
    return 0;
}

int fake_permission() {
    if (script.permission_result != 0) errno = script.permission_error;
    return script.permission_result;
}

int fake_open() {
    ++script.open_count;
    if (script.fd < 0) errno = script.open_error;
    return script.fd;
}

int fake_query(int fd, uint32_t *heap_count) {
    assert(fd == script.fd);
    ++script.query_count;
    if (script.query_result != 0) {
        errno = script.query_error;
        return -1;
    }
    *heap_count = script.heaps;
    return 0;
}

int fake_close(int fd) {
    assert(fd == script.fd);
    ++script.close_count;
    return 0;
}

const Syscalls kFakeSyscalls{fake_stat, fake_permission, fake_open, fake_query, fake_close};

void reset() {
    script = Script{};
}

} // namespace

int main() {
    reset();
    script.stat_result = -1;
    script.stat_error = ENOENT;
    const Result absent = probe(kFakeSyscalls);
    assert(absent.path == PathStatus::Absent);
    assert(absent.read_permission == PermissionStatus::NotTested);
    assert(absent.open == OpenStatus::NotTested);
    assert(absent.heap_query == IoctlStatus::NotTested);
    assert(script.open_count == 0 && script.query_count == 0);

    reset();
    script.permission_result = -1;
    script.permission_error = EACCES;
    script.fd = -1;
    script.open_error = EACCES;
    const Result denied = probe(kFakeSyscalls);
    assert(denied.path == PathStatus::Present);
    assert(denied.read_permission == PermissionStatus::Denied);
    assert(denied.open == OpenStatus::Denied);
    assert(denied.heap_query == IoctlStatus::NotTested);

    reset();
    script.query_result = -1;
    script.query_error = ENOTTY;
    const Result unsupported = probe(kFakeSyscalls);
    assert(unsupported.open == OpenStatus::Opened);
    assert(unsupported.heap_query == IoctlStatus::Unsupported);
    assert(script.close_count == 1);

    reset();
    script.heaps = 0;
    const Result supported = probe(kFakeSyscalls);
    assert(supported.path == PathStatus::Present);
    assert(supported.read_permission == PermissionStatus::Allowed);
    assert(supported.open == OpenStatus::Opened);
    assert(supported.heap_query == IoctlStatus::Supported);
    assert(supported.heap_count == 0);
    assert(script.close_count == 1);
    assert(format(supported) == "ION_PROBE\tPRESENT\tALLOWED\tOPENED\tSUPPORTED\t0");

    puts("ion_probe_test: ok");
    return 0;
}
