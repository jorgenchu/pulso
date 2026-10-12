#include "CPulso.h"

#include <sys/types.h>
#include <sys/socket.h>
#include <sys/sysctl.h>
#include <net/if.h>
#include <net/if_dl.h>
#include <net/route.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>

// The interface name travels in the link-level address that follows the header.
// Reading it from there avoids if_indextoname(), which walks every interface on
// each call and would make a pass over N interfaces cost N².
static int CopyInterfaceName(const struct if_msghdr2 *info, const char *messageEnd, char *name, size_t capacity) {
    const struct sockaddr_dl *link = (const struct sockaddr_dl *)(info + 1);
    const char *data = (const char *)link + offsetof(struct sockaddr_dl, sdl_data);
    if ((info->ifm_addrs & RTA_IFP) && data <= messageEnd && link->sdl_family == AF_LINK
        && link->sdl_nlen > 0 && link->sdl_nlen < capacity && data + link->sdl_nlen <= messageEnd) {
        memcpy(name, data, link->sdl_nlen);
        name[link->sdl_nlen] = '\0';
        return 1;
    }
    return if_indextoname(info->ifm_index, name) != NULL;
}

// getifaddrs() only exposes 32-bit counters, which wrap every 4 GB. The
// NET_RT_IFLIST2 route dump carries the 64-bit ones.
int PulsoReadInterfaceCounters(PulsoInterfaceCounters *out, int capacity) {
    if (out == NULL || capacity <= 0) return 0;

    int mib[6] = { CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0 };
    size_t length = 0;
    if (sysctl(mib, 6, NULL, &length, NULL, 0) != 0 || length == 0) return 0;

    // Interfaces can appear between the sizing call and the read.
    length += length / 4;
    char *buffer = malloc(length);
    if (buffer == NULL) return 0;
    if (sysctl(mib, 6, buffer, &length, NULL, 0) != 0) {
        free(buffer);
        return 0;
    }

    int written = 0;
    char *end = buffer + length;
    char *next = buffer;
    while (next + sizeof(struct if_msghdr) <= end && written < capacity) {
        struct if_msghdr *header = (struct if_msghdr *)next;
        if (header->ifm_msglen == 0) break;
        if (header->ifm_type == RTM_IFINFO2 && next + sizeof(struct if_msghdr2) <= end) {
            struct if_msghdr2 *info = (struct if_msghdr2 *)next;
            PulsoInterfaceCounters *entry = &out[written];
            memset(entry, 0, sizeof(*entry));
            if (CopyInterfaceName(info, next + header->ifm_msglen, entry->name, sizeof(entry->name))) {
                entry->bytesIn = info->ifm_data.ifi_ibytes;
                entry->bytesOut = info->ifm_data.ifi_obytes;
                entry->flags = (uint32_t)info->ifm_flags;
                entry->type = info->ifm_data.ifi_type;
                written++;
            }
        }
        next += header->ifm_msglen;
    }
    free(buffer);
    return written;
}
