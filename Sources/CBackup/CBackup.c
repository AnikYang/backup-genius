#include "CBackup.h"
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <sys/attr.h>
#include <unistd.h>

int bg_flush(int fd, int full) {
    int result;
    if (full) {
        do {
            result = fcntl(fd, F_FULLFSYNC);
        } while (result == -1 && errno == EINTR);
        if (result == 0) return 0;
        if (errno != ENOTSUP && errno != EINVAL && errno != ENOTTY) return -1;
    }
    do {
        result = fsync(fd);
    } while (result == -1 && errno == EINTR);
    return result;
}

int bg_set_birth_time(int fd, struct timespec time) {
    struct attrlist attrs = {0};
    attrs.bitmapcount = ATTR_BIT_MAP_COUNT;
    attrs.commonattr = ATTR_CMN_CRTIME;
    return fsetattrlist(fd, &attrs, &time, sizeof(time), 0);
}

int bg_rename_exclusive(int from_fd, const char *from, int to_fd, const char *to) {
    return renameatx_np(from_fd, from, to_fd, to, RENAME_EXCL);
}
