#pragma once

#include <sys/types.h>
#include <time.h>

int bg_flush(int fd, int full);
int bg_set_birth_time(int fd, struct timespec time);
int bg_rename_exclusive(int from_fd, const char *from, int to_fd, const char *to);
