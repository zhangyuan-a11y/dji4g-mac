#include "cmacnet.h"

#include <string.h>
#include <stdlib.h>
#include <ifaddrs.h>
#include <net/if.h>
#include <net/if_dl.h>
#include <net/route.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <sys/sysctl.h>
#include <arpa/inet.h>

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>

static int match_usb_parent(io_registry_entry_t entry, uint16_t vendorID, uint16_t productID)
{
    io_registry_entry_t current = entry;
    IOObjectRetain(current);
    int matched = 0;
    for (int depth = 0; depth < 24 && !matched; depth++) {
        CFTypeRef vidRef = IORegistryEntryCreateCFProperty(
            current, CFSTR("idVendor"), kCFAllocatorDefault, 0);
        CFTypeRef pidRef = IORegistryEntryCreateCFProperty(
            current, CFSTR("idProduct"), kCFAllocatorDefault, 0);
        if (vidRef && pidRef) {
            int vid = 0, pid = 0;
            CFNumberGetValue((CFNumberRef)vidRef, kCFNumberIntType, &vid);
            CFNumberGetValue((CFNumberRef)pidRef, kCFNumberIntType, &pid);
            if ((uint16_t)vid == vendorID && (uint16_t)pid == productID) {
                matched = 1;
            }
        }
        if (vidRef) CFRelease(vidRef);
        if (pidRef) CFRelease(pidRef);
        if (matched) break;

        io_registry_entry_t parent = 0;
        if (IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent) != KERN_SUCCESS) break;
        IOObjectRelease(current);
        current = parent;
    }
    IOObjectRelease(current);
    return matched;
}

static int collect(uint16_t vendorID, uint16_t productID, char *buffer, size_t bufferLen,
                   int wantAll, int *written)
{
    *written = 0;
    if (bufferLen == 0) return 0;
    buffer[0] = '\0';

    CFMutableDictionaryRef matching = IOServiceMatching("IOEthernetInterface");
    if (!matching) return 0;

    io_iterator_t iterator = 0;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) != KERN_SUCCESS) {
        return 0;
    }

    size_t used = 0;
    io_object_t service = 0;
    while ((service = IOIteratorNext(iterator))) {
        io_registry_entry_t parent = 0;
        io_registry_entry_t provider = service;
        IOObjectRetain(provider);
        int ownsProvider = 1;

        // The BSD name lives on the IONetworkInterface provider.
        CFTypeRef bsdName = IORegistryEntryCreateCFProperty(
            service, CFSTR("BSD Name"), kCFAllocatorDefault, 0);
        if (!bsdName) {
            if (IORegistryEntryGetParentEntry(provider, kIOServicePlane, &parent) == KERN_SUCCESS) {
                bsdName = IORegistryEntryCreateCFProperty(
                    parent, CFSTR("BSD Name"), kCFAllocatorDefault, 0);
                IOObjectRelease(parent);
                if (bsdName) {
                    IOObjectRelease(provider);
                    provider = parent;
                    ownsProvider = 0;
                }
            }
        }
        if (ownsProvider && provider) IOObjectRelease(provider);

        if (bsdName) {
            char name[64] = {0};
            if (CFStringGetCString((CFStringRef)bsdName, name, sizeof(name), kCFStringEncodingUTF8)) {
                if (match_usb_parent(service, vendorID, productID)) {
                    size_t len = strlen(name);
                    if (used + len + 2 < bufferLen) {
                        if (used > 0) buffer[used++] = ',';
                        memcpy(buffer + used, name, len);
                        used += len;
                        buffer[used] = '\0';
                        (*written)++;
                    }
                    if (!wantAll && *written >= 1) {
                        CFRelease(bsdName);
                        IOObjectRelease(service);
                        break;
                    }
                }
            }
            CFRelease(bsdName);
        }
        IOObjectRelease(service);
    }
    IOObjectRelease(iterator);
    return *written;
}

int cmacnet_usb_ethernet(uint16_t vendorID, uint16_t productID, char *nameOut, size_t nameLen)
{
    if (!nameOut || nameLen == 0) return 0;
    int written = 0;
    char scratch[256];
    collect(vendorID, productID, scratch, sizeof(scratch), 0, &written);
    if (written == 0) {
        nameOut[0] = '\0';
        return 0;
    }
    char *comma = strchr(scratch, ',');
    if (comma) *comma = '\0';
    strncpy(nameOut, scratch, nameLen - 1);
    nameOut[nameLen - 1] = '\0';
    return 1;
}

int cmacnet_usb_ethernet_all(uint16_t vendorID, uint16_t productID, char *namesOut, size_t namesLen)
{
    int written = 0;
    collect(vendorID, productID, namesOut, namesLen, 1, &written);
    return written;
}

/// Same walk as `collect()`, with the condition turned inside out: instead of
/// asking each interface "what is your BSD name", it counts the ones that never
/// got one. See the header for why that state exists and why it matters.
///
/// The parent lookup is written out again rather than shared with `collect()`:
/// that one releases the parent as soon as it has read the name off it, and
/// leaning on it here would mean changing the path the interface discovery has
/// been running on for weeks. This is a read-only probe bolted on beside it.
int cmacnet_usb_ethernet_unnamed(uint16_t vendorID, uint16_t productID)
{
    if (vendorID == 0) return 0;

    CFMutableDictionaryRef matching = IOServiceMatching("IOEthernetInterface");
    if (!matching) return 0;

    io_iterator_t iterator = 0;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) != KERN_SUCCESS) {
        return 0;
    }

    int found = 0;
    io_object_t service = 0;
    while ((service = IOIteratorNext(iterator))) {
        CFTypeRef bsdName = IORegistryEntryCreateCFProperty(
            service, CFSTR("BSD Name"), kCFAllocatorDefault, 0);
        if (!bsdName) {
            // Some builds hang the name on the provider instead.
            io_registry_entry_t parent = 0;
            if (IORegistryEntryGetParentEntry(service, kIOServicePlane, &parent) == KERN_SUCCESS) {
                bsdName = IORegistryEntryCreateCFProperty(
                    parent, CFSTR("BSD Name"), kCFAllocatorDefault, 0);
                IOObjectRelease(parent);
            }
        }
        // No name anywhere on it, and it belongs to our module: this is the
        // interface the system left behind.
        if (!bsdName && match_usb_parent(service, vendorID, productID)) {
            found++;
        }
        if (bsdName) CFRelease(bsdName);
        IOObjectRelease(service);
    }
    IOObjectRelease(iterator);
    return found;
}

/// `IOConsoleLocked` lives on the root of the service plane. Reading it is a
/// property lookup on an entry the kernel already keeps — no subprocess, no
/// permission prompt, nothing that can go stale.
int cmacnet_console_locked(void)
{
    io_registry_entry_t root = IORegistryGetRootEntry(kIOMainPortDefault);
    if (!root) return 0;
    CFTypeRef value = IORegistryEntryCreateCFProperty(
        root, CFSTR("IOConsoleLocked"), kCFAllocatorDefault, 0);
    IOObjectRelease(root);
    if (!value) return 0;
    int locked = 0;
    if (CFGetTypeID(value) == CFBooleanGetTypeID()) {
        locked = CFBooleanGetValue((CFBooleanRef)value) ? 1 : 0;
    }
    CFRelease(value);
    return locked;
}

int cmacnet_interface_counters(const char *bsdName, uint64_t *bytesIn, uint64_t *bytesOut)
{
    if (!bsdName || !bytesIn || !bytesOut) return 0;
    *bytesIn = 0;
    *bytesOut = 0;
    if (strcmp(bsdName, "lo0") == 0 || strcmp(bsdName, "gif0") == 0 || strcmp(bsdName, "stf0") == 0) return 0;

    int mib[6] = { CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0 };
    size_t length = 0;
    if (sysctl(mib, 6, NULL, &length, NULL, 0) < 0 || length == 0) return 0;

    char *buffer = malloc(length);
    if (!buffer) return 0;
    if (sysctl(mib, 6, buffer, &length, NULL, 0) < 0) {
        free(buffer);
        return 0;
    }

    int found = 0;
    char *cursor = buffer;
    char *end = buffer + length;
    while (cursor < end && !found) {
        struct if_msghdr *header = (struct if_msghdr *)cursor;
        if (header->ifm_msglen <= 0) break;
        if (header->ifm_type == RTM_IFINFO2) {
            struct if_msghdr2 *info = (struct if_msghdr2 *)header;
            struct sockaddr_dl *link = (struct sockaddr_dl *)(info + 1);
            if (link->sdl_nlen > 0 && link->sdl_nlen < 64) {
                char name[64];
                memcpy(name, link->sdl_data, link->sdl_nlen);
                name[link->sdl_nlen] = '\0';
                if (strcmp(name, bsdName) == 0) {
                    *bytesIn = info->ifm_data.ifi_ibytes;
                    *bytesOut = info->ifm_data.ifi_obytes;
                    found = 1;
                }
            }
        }
        cursor += header->ifm_msglen;
    }
    free(buffer);
    return found;
}

int cmacnet_interface_has_ipv4(const char *bsdName)
{
    char address[64];
    cmacnet_interface_ipv4(bsdName, address, sizeof(address));
    return address[0] != '\0';
}

void cmacnet_interface_ipv4(const char *bsdName, char *out, size_t outLen)
{
    if (!out || outLen == 0) return;
    out[0] = '\0';
    if (!bsdName) return;

    struct ifaddrs *list = NULL;
    if (getifaddrs(&list) != 0 || !list) return;

    for (struct ifaddrs *entry = list; entry; entry = entry->ifa_next) {
        if (!entry->ifa_addr) continue;
        if (entry->ifa_addr->sa_family != AF_INET) continue;
        if (strcmp(entry->ifa_name, bsdName) != 0) continue;
        const struct sockaddr_in *address = (const struct sockaddr_in *)entry->ifa_addr;
        if (inet_ntop(AF_INET, &address->sin_addr, out, (socklen_t)outLen) == NULL) {
            out[0] = '\0';
        }
        break;
    }
    freeifaddrs(list);
}

/* ── default route ──────────────────────────────────────────────────────── */

/// Every byte after the address family is zero — used for netmasks, which
/// macOS stores either as an `AF_INET` sockaddr or as a family-less one
/// depending on how the route got there.
static int message_sockaddr_is_all_zero(const struct sockaddr *address)
{
    size_t header = offsetof(struct sockaddr, sa_data);
    if (address->sa_len <= header) return 1;
    const unsigned char *bytes = (const unsigned char *)address->sa_data;
    for (size_t index = 0; index < (size_t)(address->sa_len - header); index++) {
        if (bytes[index] != 0) return 0;
    }
    return 1;
}

/// Is this routing message the IPv4 default route — destination 0.0.0.0 **and**
/// netmask 0.0.0.0?
///
/// The netmask half is not decoration: a VPN that routes `0.0.0.0/1` and
/// `128.0.0.0/1` to capture everything has a destination of 0.0.0.0 too, and
/// calling that the default route would hand a customer's VPN back to Wi-Fi.
static int message_is_default_route(const struct rt_msghdr *header)
{
    char *cursor = (char *)(header + 1);
    char *end = (char *)header + header->rtm_msglen;
    int sawDestination = 0;
    int destinationIsZero = 0;

    for (int bit = 0; bit < RTAX_MAX && cursor < end; bit++) {
        if ((header->rtm_addrs & (1 << bit)) == 0) continue;
        const struct sockaddr *address = (const struct sockaddr *)cursor;
        if (address->sa_len == 0) break;
        if (bit == RTAX_DST) {
            sawDestination = 1;
            destinationIsZero = address->sa_family == AF_INET
                && ((const struct sockaddr_in *)address)->sin_addr.s_addr == 0;
        } else if (bit == RTAX_NETMASK) {
            if (!message_sockaddr_is_all_zero(address)) return 0;
        }
        cursor += (address->sa_len + 3) & ~3;
    }
    return sawDestination && destinationIsZero;
}

int cmacnet_default_route_interface(char *out, size_t outLen)
{
    if (!out || outLen == 0) return 0;
    out[0] = '\0';

    int mib[6] = { CTL_NET, PF_ROUTE, 0, AF_INET, NET_RT_DUMP, 0 };
    size_t length = 0;
    if (sysctl(mib, 6, NULL, &length, NULL, 0) < 0 || length == 0) return 0;

    char *buffer = malloc(length);
    if (!buffer) return 0;
    if (sysctl(mib, 6, buffer, &length, NULL, 0) < 0) {
        free(buffer);
        return 0;
    }

    // Routes can be duplicated per interface scope; the unscoped one is the
    // machine-wide default, so it wins over anything found earlier.
    int found = 0;
    int foundScoped = 0;
    char *cursor = buffer;
    char *end = buffer + length;
    while (cursor + sizeof(struct rt_msghdr) <= end) {
        struct rt_msghdr *header = (struct rt_msghdr *)cursor;
        if (header->rtm_msglen < sizeof(struct rt_msghdr)) break;
        char *next = cursor + header->rtm_msglen;
        if (next > end) break;

        if (header->rtm_type == RTM_GET && header->rtm_index != 0
            && (header->rtm_flags & RTF_UP)
            && (header->rtm_flags & (RTF_REJECT | RTF_BLACKHOLE)) == 0
            && message_is_default_route(header)) {
            int scoped = (header->rtm_flags & RTF_IFSCOPE) != 0;
            if (!found || (foundScoped && !scoped)) {
                char name[IF_NAMESIZE];
                if (if_indextoname(header->rtm_index, name) != NULL) {
                    strncpy(out, name, outLen - 1);
                    out[outLen - 1] = '\0';
                    found = 1;
                    foundScoped = scoped;
                }
            }
        }
        cursor = next;
    }
    free(buffer);
    return found;
}
