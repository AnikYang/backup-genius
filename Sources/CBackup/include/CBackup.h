#pragma once

#include <sys/types.h>
#include <time.h>

int bg_flush(int fd, int full);
int bg_set_birth_time(int fd, struct timespec time);
int bg_rename_exclusive(int from_fd, const char *from, int to_fd, const char *to);

#include <stdint.h>
typedef struct {
    int status; /* 0 unavailable, 1 no device warning, 2 device warning */
    int temperature_c;
    int percentage_used;
    int zoned; /* 1 host aware, 2 device managed, 0 unknown */
} BGDiskHealth;
BGDiskHealth bg_disk_health(uint32_t media);
