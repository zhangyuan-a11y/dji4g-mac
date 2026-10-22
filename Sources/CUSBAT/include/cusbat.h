#ifndef CUSBAT_H
#define CUSBAT_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* One USB interface that exposes both a bulk-IN and a bulk-OUT endpoint and is
   therefore a candidate for the module's AT command channel. */
typedef struct {
    int interfaceNumber;
    unsigned char endpointIn;
    unsigned char endpointOut;
    unsigned char interfaceClass;
    unsigned char interfaceSubClass;
    unsigned char alternateSetting;
    unsigned char interfaceCount;
} cusbat_candidate;

/* Result of cusbat_open_auto. */
typedef struct {
    int interfaceNumber;
    unsigned char endpointIn;
    unsigned char endpointOut;
    char probeResponse[64];
    /* 1 when the session came through the interface-level fallback because the
       device-level channel was refused. */
    int interfaceOnly;
} cusbat_open_info;

/* One interface as seen through the read-only IORegistry view. This view needs
   no IOServiceOpen, so it stays readable while another process holds the module
   exclusively - which is exactly the state the menu bar app leaves behind. */
typedef struct {
    int interfaceNumber;
    unsigned char interfaceClass;
    unsigned char interfaceSubClass;
    unsigned char interfaceProtocol;
    int endpointCount;
    unsigned char alternateSetting;
    /* UsbExclusiveOwner, empty while the interface is free. */
    char owner[96];
} cusbat_interface_view;

/* Number of matching USB devices currently attached (no open performed). */
int cusbat_present(int vendorID, int productID);

/* Product IDs of every attached device from one vendor, without duplicates.
   Lets a whole module family be recognised by vendor (Quectel ships one vendor
   ID and several product IDs, and a new model would otherwise read as "not
   supported" until someone hard-coded it). Returns the count written to `out`,
   or a negative cusbat_status. */
int cusbat_products(int vendorID, int *out, int maxCount);

/* Read-only inventory of every interface on the first matching device, sorted
   by interface number. Performs no IOServiceOpen, so it also works while the
   module is held exclusively elsewhere. Returns the count written to `out`, or
   a negative cusbat_status. */
int cusbat_interfaces(int vendorID, int productID,
                      cusbat_interface_view *out, int maxCount);

/* Copies the UsbExclusiveOwner string of the device itself (interfaceNumber < 0)
   or of a single interface. Returns 1 when a holder was named, 0 when the node
   is free, or a negative cusbat_status. */
int cusbat_exclusive_owner(int vendorID, int productID, int interfaceNumber,
                           char *out, size_t outLen);

/* Enumerate bulk candidates for every attached device with the given identity.
   Returns the number written to `out` (never more than maxCount), or a negative
   cusbat_status value. */
int cusbat_candidates(int vendorID, int productID, cusbat_candidate *out, int maxCount);

/* Open the AT channel on a specific interface. Returns NULL on failure and
   writes a human readable reason into err (may be NULL). */
void *cusbat_open(int vendorID, int productID, int interfaceNumber,
                  unsigned char endpointIn, unsigned char endpointOut,
                  char *err, size_t errLen);

/* Enumerate candidates, claim each in turn and probe it with a plain "AT"
   command. The first interface that answers OK wins. */
void *cusbat_open_auto(int vendorID, int productID, cusbat_open_info *info,
                       char *err, size_t errLen);

/* Write bytes. Returns 0 on success, negative cusbat_status on failure. */
int cusbat_write(void *session, const unsigned char *data, int length, int timeoutMs);

/* Read up to `length` bytes. Returns the number of bytes read (0 is possible),
   or a negative cusbat_status. CUSBAT_TIMEOUT is returned when no data arrived
   before the timeout elapsed. */
int cusbat_read(void *session, unsigned char *buffer, int length, int timeoutMs);

/* Human readable description of the last error for the session. */
const char *cusbat_last_error(void *session);

void cusbat_close(void *session);

/* Status codes are exported as plain integers so Swift imports them directly. */
#define CUSBAT_OK                    0
#define CUSBAT_ERR_INIT             -1
#define CUSBAT_ERR_NOT_FOUND        -2
#define CUSBAT_ERR_NO_CANDIDATE     -3
#define CUSBAT_ERR_OPEN_DEVICE      -4
#define CUSBAT_ERR_CLAIM            -5
#define CUSBAT_ERR_NO_PIPE          -6
#define CUSBAT_ERR_WRITE            -7
#define CUSBAT_ERR_READ             -8
#define CUSBAT_ERR_TIMEOUT          -9
#define CUSBAT_ERR_BUFFER_TOO_SMALL -10
#define CUSBAT_ERR_NOT_OPEN         -11

#ifdef __cplusplus
}
#endif

#endif /* CUSBAT_H */
