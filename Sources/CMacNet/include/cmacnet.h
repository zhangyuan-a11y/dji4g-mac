#ifndef CMACNET_H
#define CMACNET_H

#include <stdint.h>
#include <stddef.h>

/// Finds the BSD interface name (e.g. "en7") of the Ethernet-like interface
/// that sits behind a USB device with this VID/PID. Returns 1 when found.
int cmacnet_usb_ethernet(uint16_t vendorID, uint16_t productID,
                         char *nameOut, size_t nameLen);

/// Lists every Ethernet-like BSD interface belonging to that USB device,
/// separated by commas. Returns the number written (may be 0).
int cmacnet_usb_ethernet_all(uint16_t vendorID, uint16_t productID,
                             char *namesOut, size_t namesLen);

/// How many Ethernet-like interfaces belong to that USB device but were **left
/// without a BSD name** by the system. Returns 0 when `vendorID` is 0.
///
/// Why this exists (2026-09-27, reproduced three times on the delivery Mac):
/// while the console is locked, macOS refuses to name a network interface that
/// has just appeared. `configd` says so in as many words --
///
///     Console locked, network interface[matching] ignored:
///     path = .../Baiwang@14100000/IOUSBHostInterface@5/AppleUSBECMData/IOEthernetInterface
///
/// -- and it never comes back to do the naming later. Unlocking does not help:
/// the interface stays in IOKit without a `BSD Name` for good. To the customer
/// this reads as "the module is plugged in and lit up, but there is no
/// internet", and asking again never fixes it, because every question this app
/// used to ask was "what is the interface called".
///
/// A non-zero answer therefore means: the module enumerated fine, the system
/// dropped its half of the job, and the only way out is to make the module
/// enumerate a second time.
int cmacnet_usb_ethernet_unnamed(uint16_t vendorID, uint16_t productID);

/// True while the console is locked (screen locked, or the login window is up).
///
/// Used together with `cmacnet_usb_ethernet_unnamed()`: a re-enumeration
/// attempted while the console is locked is ignored for exactly the same
/// reason, so the caller waits for the customer to come back instead of
/// power-cycling the module for nothing.
int cmacnet_console_locked(void);

/// 64-bit byte counters for a BSD interface. Returns 1 on success.
int cmacnet_interface_counters(const char *bsdName,
                               uint64_t *bytesIn, uint64_t *bytesOut);

/// True when the interface currently has an IPv4 address.
int cmacnet_interface_has_ipv4(const char *bsdName);

/// Primary IPv4 address of the interface, or an empty string.
void cmacnet_interface_ipv4(const char *bsdName, char *out, size_t outLen);

/// BSD name of the interface the IPv4 default route currently points at
/// (e.g. "en0"), or an empty string when the machine has no default route at
/// all. Returns 1 when a name was written.
///
/// Why this exists (2026-09-26, found on the delivery build): the safety net
/// that hands the default route back to Wi-Fi used to decide whether to act by
/// reading a cached "is the module's network service switched on" flag. That
/// flag is only refreshed on the expensive path, so whenever the route ended up
/// on the module some *other* way — service enabled from a terminal, macOS
/// restoring it across a USB re-enumeration, the app having just restarted —
/// the safety net believed it had nothing to do with the module and sat still.
/// Measured on the real module: 90 seconds with the whole machine offline and
/// not one reaction.
///
/// "Is the default route on the module's interface" is the question the safety
/// net actually needs answered, and the routing table answers it here and now:
/// no subprocess, no AT command, nothing that can go stale.
int cmacnet_default_route_interface(char *out, size_t outLen);

#endif /* CMACNET_H */
