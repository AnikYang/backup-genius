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

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/storage/ata/ATASMARTLib.h>
#include <IOKit/storage/nvme/NVMeSMARTLibExternal.h>
#include <libkern/OSByteOrder.h>
#include <string.h>

BGDiskHealth bg_disk_health(uint32_t media) {
    BGDiskHealth result = {0, -999, -1, 0};
    io_registry_entry_t entry = media;
    IOObjectRetain(entry);
    for (int depth = 0; entry && depth < 24; ++depth) {
        CFTypeRef nvme = IORegistryEntryCreateCFProperty(entry, CFSTR("NVMe SMART Capable"), kCFAllocatorDefault, 0);
        CFTypeRef ata = IORegistryEntryCreateCFProperty(entry, CFSTR("SMART Capable"), kCFAllocatorDefault, 0);
        int isNVMe = nvme && CFEqual(nvme, kCFBooleanTrue);
        int isATA = ata && CFEqual(ata, kCFBooleanTrue);
        if (nvme) CFRelease(nvme);
        if (ata) CFRelease(ata);
        IOCFPlugInInterface **plugin = NULL;
        SInt32 score = 0;
        if ((isNVMe || isATA) && IOCreatePlugInInterfaceForService(entry,
            isNVMe ? kIONVMeSMARTUserClientTypeID : kIOATASMARTUserClientTypeID,
            kIOCFPlugInInterfaceID, &plugin, &score) == kIOReturnSuccess && plugin) {
            if (isNVMe) {
                IONVMeSMARTInterface **smart = NULL;
                if ((*plugin)->QueryInterface(plugin, CFUUIDGetUUIDBytes(kIONVMeSMARTInterfaceID), (LPVOID *)&smart) == S_OK && smart) {
                    NVMeSMARTData data;
                    memset(&data, 0, sizeof(data));
                    if ((*smart)->SMARTReadData(smart, &data) == kIOReturnSuccess) {
                        result.status = data.CRITICAL_WARNING ? 2 : 1;
                        result.percentage_used = data.PERCENTAGE_USED;
                        unsigned temperature = OSSwapLittleToHostInt16(data.TEMPERATURE);
                        if (temperature) result.temperature_c = (int)temperature - 273;
                    }
                    (*smart)->Release(smart);
                }
            } else {
                IOATASMARTInterface **smart = NULL;
                if ((*plugin)->QueryInterface(plugin, CFUUIDGetUUIDBytes(kIOATASMARTInterfaceID), (LPVOID *)&smart) == S_OK && smart) {
                    Boolean exceeded = false;
                    if ((*smart)->SMARTReturnStatus(smart, &exceeded) == kIOReturnSuccess) result.status = exceeded ? 2 : 1;
                    uint16_t words[256] = {0};
                    UInt32 size = 0;
                    if ((*smart)->GetATAIdentifyData(smart, words, sizeof(words), &size) == kIOReturnSuccess && size == sizeof(words)) {
                        int zoned = words[69] & 3;
                        if (zoned == 1 || zoned == 2) result.zoned = zoned;
                    }
                    (*smart)->Release(smart);
                }
            }
            IODestroyPlugInInterface(plugin);
        }
        io_registry_entry_t parent = 0;
        if (result.status || IORegistryEntryGetParentEntry(entry, kIOServicePlane, &parent) != KERN_SUCCESS) {
            IOObjectRelease(entry);
            return result;
        }
        IOObjectRelease(entry);
        entry = parent;
    }
    if (entry) IOObjectRelease(entry);
    return result;
}
