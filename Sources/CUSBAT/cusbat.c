#include "cusbat.h"

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/usb/IOUSBLib.h>
#include <IOKit/usb/USBSpec.h>

#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define CUSBAT_DEFAULT_TIMEOUT_MS 1000

/* USB descriptor types used while parsing the configuration block. */
#define CUSBAT_DESC_CONFIG 2

struct cusbat_session {
    IOUSBDeviceInterface500    **device;
    IOUSBInterfaceInterface500 **interface;
    io_service_t              deviceService;
    io_service_t              interfaceService;
    UInt8                     pipeIn;
    UInt8                     pipeOut;
    char                      lastError[192];
};

static void set_error(struct cusbat_session *s, const char *fmt, ...)
{
    if (s == NULL) {
        return;
    }
    va_list args;
    va_start(args, fmt);
    vsnprintf(s->lastError, sizeof(s->lastError), fmt, args);
    va_end(args);
}

static int cf_number_to_int(io_service_t service, CFStringRef key)
{
    CFTypeRef value = IORegistryEntryCreateCFProperty(service, key, kCFAllocatorDefault, 0);
    if (value == NULL) {
        return -1;
    }
    int result = -1;
    if (CFGetTypeID(value) == CFNumberGetTypeID()) {
        CFNumberGetValue((CFNumberRef)value, kCFNumberIntType, &result);
    }
    CFRelease(value);
    return result;
}

static unsigned char cf_number_to_byte(io_service_t service, CFStringRef key)
{
    int value = cf_number_to_int(service, key);
    if (value < 0 || value > 255) {
        return 0;
    }
    return (unsigned char)value;
}

static int cf_string_to_buf(io_service_t service, CFStringRef key, char *out, size_t outLen)
{
    if (out == NULL || outLen == 0) {
        return 0;
    }
    out[0] = '\0';
    CFTypeRef value = IORegistryEntryCreateCFProperty(service, key, kCFAllocatorDefault, 0);
    if (value == NULL) {
        return 0;
    }
    int found = 0;
    if (CFGetTypeID(value) == CFStringGetTypeID()) {
        found = CFStringGetCString((CFStringRef)value, out, (CFIndex)outLen, kCFStringEncodingUTF8) ? 1 : 0;
    }
    CFRelease(value);
    return found;
}

/* 设备级 USB 通道被卡住时的几个状态码。它们既不是「没插线」，也不是「模块坏
   了」，而是系统拒绝再给这个设备建新的访问通道。客人此时会看到一句「模块已
   连接但读不到描述」——那句话会把他引到换线、换电脑上去，而真正的解法只有一
   个：让设备重新枚举一次（拔插数据线）。这几个码也出现在别的程序把设备级句柄
   攥坏之后，所以提示统一写在这里。 */
static int is_stuck_usb_error(IOReturn result)
{
    return result == kIOReturnNotPermitted
        || result == kIOReturnUnsupported
        || result == kIOReturnNoResources
        || result == kIOReturnInternalError;
}

/* 卡住时给一句能照做的整句。这句话里不点接口号：卡住是整台设备的事，点了
   接口号反而会把人引到「哪个接口坏了」上去；而「权限不足」和「通道卡住」
   在这几个状态码上是同一副面孔，所以两句都写进去，先做的放在前面。 */
static const char *stuck_usb_sentence(void)
{
    return "模块的 USB 访问通道被系统挡住了；先拔掉数据线等 5 秒再插回，仍不行就把程序退出重开";
}

static struct cusbat_session *make_session(IOUSBInterfaceInterface500 **interface,
                                           io_service_t interfaceService,
                                           IOUSBDeviceInterface500 **device,
                                           io_service_t deviceService,
                                           UInt8 pipeIn, UInt8 pipeOut)
{
    struct cusbat_session *session = calloc(1, sizeof(struct cusbat_session));
    if (session == NULL) {
        return NULL;
    }
    session->device = device;
    session->deviceService = deviceService;
    session->interface = interface;
    session->interfaceService = interfaceService;
    session->pipeIn = pipeIn;
    session->pipeOut = pipeOut;
    return session;
}

/* First attached device with the given identity, or MACH_PORT_NULL. The caller
   owns the returned reference. */
static io_service_t copy_first_matching_device(int vendorID, int productID)
{
    CFMutableDictionaryRef matching = IOServiceMatching("IOUSBHostDevice");
    if (matching == NULL) {
        return MACH_PORT_NULL;
    }
    io_iterator_t iterator = MACH_PORT_NULL;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) != KERN_SUCCESS) {
        return MACH_PORT_NULL;
    }

    io_service_t found = MACH_PORT_NULL;
    io_service_t service = MACH_PORT_NULL;
    while ((service = IOIteratorNext(iterator)) != MACH_PORT_NULL) {
        if (found == MACH_PORT_NULL &&
            cf_number_to_int(service, CFSTR("idVendor")) == vendorID &&
            cf_number_to_int(service, CFSTR("idProduct")) == productID) {
            found = service;
        } else {
            IOObjectRelease(service);
        }
    }
    IOObjectRelease(iterator);
    return found;
}

int cusbat_present(int vendorID, int productID)
{
    CFMutableDictionaryRef matching = IOServiceMatching("IOUSBHostDevice");
    if (matching == NULL) {
        return CUSBAT_ERR_INIT;
    }
    io_iterator_t iterator = MACH_PORT_NULL;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) != KERN_SUCCESS) {
        return CUSBAT_ERR_INIT;
    }
    int found = 0;
    io_service_t service = MACH_PORT_NULL;
    while ((service = IOIteratorNext(iterator)) != MACH_PORT_NULL) {
        if (cf_number_to_int(service, CFSTR("idVendor")) == vendorID &&
            cf_number_to_int(service, CFSTR("idProduct")) == productID) {
            found += 1;
        }
        IOObjectRelease(service);
    }
    IOObjectRelease(iterator);
    return found;
}

int cusbat_products(int vendorID, int *out, int maxCount)
{
    if (out == NULL || maxCount <= 0) {
        return CUSBAT_ERR_BUFFER_TOO_SMALL;
    }
    CFMutableDictionaryRef matching = IOServiceMatching("IOUSBHostDevice");
    if (matching == NULL) {
        return CUSBAT_ERR_INIT;
    }
    io_iterator_t iterator = MACH_PORT_NULL;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) != KERN_SUCCESS) {
        return CUSBAT_ERR_INIT;
    }
    int found = 0;
    io_service_t service = MACH_PORT_NULL;
    while ((service = IOIteratorNext(iterator)) != MACH_PORT_NULL) {
        if (cf_number_to_int(service, CFSTR("idVendor")) == vendorID) {
            int product = cf_number_to_int(service, CFSTR("idProduct"));
            /* Two of the same dongle plugged in at once must not fill the
               buffer with the same product ID — the caller opens by identity,
               so the duplicates would only cost a second probe. */
            int seen = 0;
            for (int index = 0; index < found; index++) {
                if (out[index] == product) {
                    seen = 1;
                    break;
                }
            }
            if (!seen && found < maxCount) {
                out[found] = product;
                found += 1;
            }
        }
        IOObjectRelease(service);
    }
    IOObjectRelease(iterator);
    return found;
}

int cusbat_exclusive_owner(int vendorID, int productID, int interfaceNumber,
                           char *out, size_t outLen)
{
    if (out == NULL || outLen == 0) {
        return CUSBAT_ERR_BUFFER_TOO_SMALL;
    }
    out[0] = '\0';

    io_service_t device = copy_first_matching_device(vendorID, productID);
    if (device == MACH_PORT_NULL) {
        return CUSBAT_ERR_NOT_FOUND;
    }

    if (interfaceNumber < 0) {
        int found = cf_string_to_buf(device, CFSTR("UsbExclusiveOwner"), out, outLen);
        IOObjectRelease(device);
        return found;
    }

    io_iterator_t children = MACH_PORT_NULL;
    if (IORegistryEntryGetChildIterator(device, kIOServicePlane, &children) != KERN_SUCCESS) {
        IOObjectRelease(device);
        return CUSBAT_ERR_INIT;
    }

    int found = 0;
    io_registry_entry_t child = MACH_PORT_NULL;
    while ((child = IOIteratorNext(children)) != MACH_PORT_NULL) {
        io_name_t className = {0};
        IOObjectGetClass(child, className);
        if (strcmp(className, "IOUSBInterface") == 0 &&
            cf_number_to_int(child, CFSTR("bInterfaceNumber")) == interfaceNumber) {
            found = cf_string_to_buf(child, CFSTR("UsbExclusiveOwner"), out, outLen);
        }
        IOObjectRelease(child);
    }
    IOObjectRelease(children);
    IOObjectRelease(device);
    return found;
}

int cusbat_interfaces(int vendorID, int productID,
                      cusbat_interface_view *out, int maxCount)
{
    if (out == NULL || maxCount <= 0) {
        return CUSBAT_ERR_BUFFER_TOO_SMALL;
    }

    io_service_t device = copy_first_matching_device(vendorID, productID);
    if (device == MACH_PORT_NULL) {
        return CUSBAT_ERR_NOT_FOUND;
    }

    io_iterator_t children = MACH_PORT_NULL;
    if (IORegistryEntryGetChildIterator(device, kIOServicePlane, &children) != KERN_SUCCESS) {
        IOObjectRelease(device);
        return CUSBAT_ERR_INIT;
    }

    int count = 0;
    io_registry_entry_t child = MACH_PORT_NULL;
    while ((child = IOIteratorNext(children)) != MACH_PORT_NULL) {
        io_name_t className = {0};
        IOObjectGetClass(child, className);
        if (strcmp(className, "IOUSBInterface") == 0 && count < maxCount) {
            cusbat_interface_view *view = &out[count];
            memset(view, 0, sizeof(*view));
            view->interfaceNumber = cf_number_to_int(child, CFSTR("bInterfaceNumber"));
            view->interfaceClass = cf_number_to_byte(child, CFSTR("bInterfaceClass"));
            view->interfaceSubClass = cf_number_to_byte(child, CFSTR("bInterfaceSubClass"));
            view->interfaceProtocol = cf_number_to_byte(child, CFSTR("bInterfaceProtocol"));
            view->endpointCount = cf_number_to_int(child, CFSTR("bNumEndpoints"));
            view->alternateSetting = cf_number_to_byte(child, CFSTR("bAlternateSetting"));
            cf_string_to_buf(child, CFSTR("UsbExclusiveOwner"), view->owner, sizeof(view->owner));
            count += 1;
        }
        IOObjectRelease(child);
    }
    IOObjectRelease(children);
    IOObjectRelease(device);

    /* Enumeration order is not part of the contract, so sort by interface
       number and let callers present a stable table. */
    for (int index = 1; index < count; index++) {
        cusbat_interface_view key = out[index];
        int scan = index - 1;
        while (scan >= 0 && out[scan].interfaceNumber > key.interfaceNumber) {
            out[scan + 1] = out[scan];
            scan -= 1;
        }
        out[scan + 1] = key;
    }
    return count;
}

/* Reads the (index 0) configuration descriptor block, including every interface
   and endpoint descriptor, using a control transfer so the result does not
   depend on the device already being configured. */
static int read_configuration_descriptor(IOUSBDeviceInterface500 **device,
                                         unsigned char *buffer, size_t capacity,
                                         size_t *outLength)
{
    IOUSBDevRequestTO request;
    memset(&request, 0, sizeof(request));
    request.bmRequestType = 0x80;
    request.bRequest = kUSBRqGetDescriptor;
    request.wValue = (CUSBAT_DESC_CONFIG << 8);
    request.wIndex = 0;
    request.wLength = sizeof(IOUSBConfigurationDescriptor);
    request.pData = buffer;
    request.noDataTimeout = 1000;
    request.completionTimeout = 2000;

    IOReturn result = (*device)->DeviceRequestTO(device, &request);
    if (result != kIOReturnSuccess || request.wLenDone < 9) {
        return CUSBAT_ERR_INIT;
    }

    size_t total = USBToHostWord(((IOUSBConfigurationDescriptor *)buffer)->wTotalLength);
    if (total < 9) {
        return CUSBAT_ERR_INIT;
    }
    if (total > capacity) {
        total = capacity;
    }

    if (total > 9) {
        memset(&request, 0, sizeof(request));
        request.bmRequestType = 0x80;
        request.bRequest = kUSBRqGetDescriptor;
        request.wValue = (CUSBAT_DESC_CONFIG << 8);
        request.wIndex = 0;
        request.wLength = (UInt16)total;
        request.pData = buffer;
        result = (*device)->DeviceRequestTO(device, &request);
        if (result != kIOReturnSuccess) {
            return CUSBAT_ERR_INIT;
        }
        total = request.wLenDone;
    }

    *outLength = total;
    return CUSBAT_OK;
}

static int collect_candidates_from_descriptor(const unsigned char *buffer, size_t length,
                                              cusbat_candidate *out, int maxCount)
{
    int count = 0;
    size_t offset = buffer[0];
    unsigned char currentInterface = 0;
    unsigned char currentAlt = 0;
    unsigned char currentClass = 0;
    unsigned char currentSubClass = 0;
    unsigned char endpointIn = 0;
    unsigned char endpointOut = 0;
    int haveInterface = 0;

    while (offset + 2 <= length) {
        unsigned char descriptorLength = buffer[offset];
        unsigned char descriptorType = buffer[offset + 1];
        if (descriptorLength < 2 || offset + descriptorLength > length) {
            break;
        }

        if (descriptorType == kUSBInterfaceDesc && descriptorLength >= 9) {
            if (haveInterface && endpointIn != 0 && endpointOut != 0 && count < maxCount) {
                out[count].interfaceNumber = currentInterface;
                out[count].alternateSetting = currentAlt;
                out[count].interfaceClass = currentClass;
                out[count].interfaceSubClass = currentSubClass;
                out[count].endpointIn = endpointIn;
                out[count].endpointOut = endpointOut;
                count += 1;
            }
            currentInterface = buffer[offset + 2];
            currentAlt = buffer[offset + 3];
            currentClass = buffer[offset + 5];
            currentSubClass = buffer[offset + 6];
            endpointIn = 0;
            endpointOut = 0;
            haveInterface = 1;
        } else if (descriptorType == kUSBEndpointDesc && descriptorLength >= 7 && haveInterface) {
            unsigned char attributes = buffer[offset + 3] & kUSBEndpointbmAttributesTransferTypeMask;
            unsigned char address = buffer[offset + 2];
            if (attributes == kUSBBulk) {
                if ((address & 0x80) != 0) {
                    endpointIn = address;
                } else {
                    endpointOut = address;
                }
            }
        }

        offset += descriptorLength;
    }

    if (haveInterface && endpointIn != 0 && endpointOut != 0 && count < maxCount) {
        out[count].interfaceNumber = currentInterface;
        out[count].alternateSetting = currentAlt;
        out[count].interfaceClass = currentClass;
        out[count].interfaceSubClass = currentSubClass;
        out[count].endpointIn = endpointIn;
        out[count].endpointOut = endpointOut;
        count += 1;
    }

    return count;
}

int cusbat_candidates(int vendorID, int productID, cusbat_candidate *out, int maxCount)
{
    if (out == NULL || maxCount <= 0) {
        return CUSBAT_ERR_BUFFER_TOO_SMALL;
    }

    CFMutableDictionaryRef matching = IOServiceMatching("IOUSBHostDevice");
    if (matching == NULL) {
        return CUSBAT_ERR_INIT;
    }
    io_iterator_t iterator = MACH_PORT_NULL;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) != KERN_SUCCESS) {
        return CUSBAT_ERR_INIT;
    }

    int total = 0;
    io_service_t service = MACH_PORT_NULL;
    while ((service = IOIteratorNext(iterator)) != MACH_PORT_NULL) {
        if (cf_number_to_int(service, CFSTR("idVendor")) != vendorID ||
            cf_number_to_int(service, CFSTR("idProduct")) != productID) {
            IOObjectRelease(service);
            continue;
        }

        IOCFPlugInInterface **plugin = NULL;
        SInt32 score = 0;
        if (IOCreatePlugInInterfaceForService(service, kIOUSBDeviceUserClientTypeID,
                                              kIOCFPlugInInterfaceID, &plugin, &score) != kIOReturnSuccess) {
            IOObjectRelease(service);
            continue;
        }
        IOUSBDeviceInterface500 **device = NULL;
        (*plugin)->QueryInterface(plugin, CFUUIDGetUUIDBytes(kIOUSBDeviceInterfaceID500), (LPVOID *)&device);
        (*plugin)->Release(plugin);
        if (device == NULL) {
            IOObjectRelease(service);
            continue;
        }
        if ((*device)->USBDeviceOpen(device) != kIOReturnSuccess) {
            (*device)->Release(device);
            IOObjectRelease(service);
            continue;
        }

        unsigned char descriptor[4096];
        size_t descriptorLength = 0;
        if (read_configuration_descriptor(device, descriptor, sizeof(descriptor), &descriptorLength) == CUSBAT_OK) {
            total += collect_candidates_from_descriptor(descriptor, descriptorLength,
                                                        out + total, maxCount - total);
        }

        (*device)->USBDeviceClose(device);
        (*device)->Release(device);
        IOObjectRelease(service);
        if (total >= maxCount) {
            break;
        }
    }

    IOObjectRelease(iterator);
    return total;
}

static void *open_interface_on_device(IOUSBDeviceInterface500 **device, io_service_t deviceService,
                                      int vendorID, int productID, int interfaceNumber,
                                      unsigned char endpointIn, unsigned char endpointOut,
                                      char *err, size_t errLen)
{
    (void)vendorID;
    (void)productID;

    IOUSBFindInterfaceRequest request;
    request.bInterfaceClass = kIOUSBFindInterfaceDontCare;
    request.bInterfaceSubClass = kIOUSBFindInterfaceDontCare;
    request.bInterfaceProtocol = kIOUSBFindInterfaceDontCare;
    request.bAlternateSetting = kIOUSBFindInterfaceDontCare;

    io_iterator_t iterator = MACH_PORT_NULL;
    if ((*device)->CreateInterfaceIterator(device, &request, &iterator) != kIOReturnSuccess) {
        if (err) snprintf(err, errLen, "无法枚举 USB 接口 %d", interfaceNumber);
        return NULL;
    }

    /* IOUSBFindInterfaceRequest carries no interface number, so candidates are
       enumerated and matched through GetInterfaceNumber instead. */
    io_service_t interfaceService = MACH_PORT_NULL;
    io_service_t candidateService = MACH_PORT_NULL;
    while ((candidateService = IOIteratorNext(iterator)) != MACH_PORT_NULL) {
        IOCFPlugInInterface **probePlugin = NULL;
        SInt32 probeScore = 0;
        IOUSBInterfaceInterface500 **probeInterface = NULL;
        if (IOCreatePlugInInterfaceForService(candidateService, kIOUSBInterfaceUserClientTypeID,
                                              kIOCFPlugInInterfaceID, &probePlugin, &probeScore) == kIOReturnSuccess) {
            (*probePlugin)->QueryInterface(probePlugin, CFUUIDGetUUIDBytes(kIOUSBInterfaceInterfaceID500),
                                           (LPVOID *)&probeInterface);
            (*probePlugin)->Release(probePlugin);
        }
        UInt8 foundNumber = 0xFF;
        if (probeInterface != NULL) {
            (*probeInterface)->GetInterfaceNumber(probeInterface, &foundNumber);
            (*probeInterface)->Release(probeInterface);
        }
        if (foundNumber == interfaceNumber) {
            interfaceService = candidateService;
            break;
        }
        IOObjectRelease(candidateService);
    }
    IOObjectRelease(iterator);
    if (interfaceService == MACH_PORT_NULL) {
        if (err) snprintf(err, errLen, "USB 接口 %d 不存在", interfaceNumber);
        return NULL;
    }

    IOCFPlugInInterface **plugin = NULL;
    SInt32 score = 0;
    if (IOCreatePlugInInterfaceForService(interfaceService, kIOUSBInterfaceUserClientTypeID,
                                          kIOCFPlugInInterfaceID, &plugin, &score) != kIOReturnSuccess) {
        IOObjectRelease(interfaceService);
        if (err) snprintf(err, errLen, "USB 接口 %d 无法创建插件", interfaceNumber);
        return NULL;
    }
    IOUSBInterfaceInterface500 **interface = NULL;
    (*plugin)->QueryInterface(plugin, CFUUIDGetUUIDBytes(kIOUSBInterfaceInterfaceID500), (LPVOID *)&interface);
    (*plugin)->Release(plugin);
    if (interface == NULL) {
        IOObjectRelease(interfaceService);
        if (err) snprintf(err, errLen, "USB 接口 %d 不支持 IOUSBInterfaceInterface", interfaceNumber);
        return NULL;
    }

    IOReturn result = (*interface)->USBInterfaceOpen(interface);
    if (result != kIOReturnSuccess) {
        (*interface)->Release(interface);
        IOObjectRelease(interfaceService);
        if (err) {
            char owner[96] = {0};
            if (result == kIOReturnExclusiveAccess &&
                cusbat_exclusive_owner(vendorID, productID, interfaceNumber, owner, sizeof(owner)) > 0) {
                snprintf(err, errLen, "USB 接口 %d 已被 %s 占用；退出该程序后再试",
                         interfaceNumber, owner);
            } else if (result == kIOReturnExclusiveAccess) {
                snprintf(err, errLen, "USB 接口 %d 已被其它程序独占；退出占用它的程序后再试",
                         interfaceNumber);
            } else {
                snprintf(err, errLen, "占用 USB 接口 %d 失败（0x%08x）", interfaceNumber, result);
            }
        }
        return NULL;
    }

    UInt8 pipeIn = 0;
    UInt8 pipeOut = 0;
    UInt8 pipeCount = 0;
    if ((*interface)->GetNumEndpoints(interface, &pipeCount) == kIOReturnSuccess) {
        for (UInt8 index = 1; index <= pipeCount; index++) {
            UInt8 direction = 0;
            UInt8 number = 0;
            UInt8 transferType = 0;
            UInt8 interval = 0;
            UInt16 maxPacketSize = 0;
            if ((*interface)->GetPipeProperties(interface, index, &direction, &number,
                                                &transferType, &maxPacketSize, &interval) != kIOReturnSuccess) {
                continue;
            }
            if (transferType != kUSBBulk) {
                continue;
            }
            unsigned char address = (unsigned char)((direction == kUSBIn ? 0x80 : 0x00) | number);
            if (address == endpointIn) pipeIn = index;
            if (address == endpointOut) pipeOut = index;
        }
    }

    if (pipeIn == 0 || pipeOut == 0) {
        (*interface)->USBInterfaceClose(interface);
        (*interface)->Release(interface);
        IOObjectRelease(interfaceService);
        if (err) snprintf(err, errLen, "USB 接口 %d 找不到 0x%02x/0x%02x 批量端点",
                          interfaceNumber, endpointOut, endpointIn);
        return NULL;
    }

    struct cusbat_session *session = make_session(interface, interfaceService, device,
                                                  deviceService, pipeIn, pipeOut);
    if (session == NULL) {
        (*interface)->USBInterfaceClose(interface);
        (*interface)->Release(interface);
        IOObjectRelease(interfaceService);
        return NULL;
    }
    if (err) {
        err[0] = '\0';
    }
    return session;
}

void *cusbat_open(int vendorID, int productID, int interfaceNumber,
                  unsigned char endpointIn, unsigned char endpointOut,
                  char *err, size_t errLen)
{
    CFMutableDictionaryRef matching = IOServiceMatching("IOUSBHostDevice");
    if (matching == NULL) {
        if (err) snprintf(err, errLen, "IOKit 初始化失败");
        return NULL;
    }
    io_iterator_t iterator = MACH_PORT_NULL;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) != KERN_SUCCESS) {
        if (err) snprintf(err, errLen, "IOKit 服务查询失败");
        return NULL;
    }

    void *session = NULL;
    io_service_t service = MACH_PORT_NULL;
    while ((service = IOIteratorNext(iterator)) != MACH_PORT_NULL) {
        if (cf_number_to_int(service, CFSTR("idVendor")) != vendorID ||
            cf_number_to_int(service, CFSTR("idProduct")) != productID) {
            IOObjectRelease(service);
            continue;
        }

        IOCFPlugInInterface **plugin = NULL;
        SInt32 score = 0;
        IOReturn plugInResult = IOCreatePlugInInterfaceForService(service, kIOUSBDeviceUserClientTypeID,
                                                                  kIOCFPlugInInterfaceID, &plugin, &score);
        if (plugInResult != kIOReturnSuccess) {
            /* Staying silent here used to surface as "device not found", which
               sends the reader chasing a cable problem that does not exist. */
            if (err) {
                if (is_stuck_usb_error(plugInResult)) {
                    snprintf(err, errLen, "%s（0x%08x）", stuck_usb_sentence(), plugInResult);
                } else {
                    snprintf(err, errLen, "无法取得模块的 USB 访问通道（0x%08x）", plugInResult);
                }
            }
            IOObjectRelease(service);
            continue;
        }
        IOUSBDeviceInterface500 **device = NULL;
        (*plugin)->QueryInterface(plugin, CFUUIDGetUUIDBytes(kIOUSBDeviceInterfaceID500), (LPVOID *)&device);
        (*plugin)->Release(plugin);
        if (device == NULL) {
            if (err) {
                snprintf(err, errLen, "模块的 USB 设备接口不可用（系统驱动未就绪）");
            }
            IOObjectRelease(service);
            continue;
        }
        IOReturn openResult = (*device)->USBDeviceOpen(device);
        if (openResult != kIOReturnSuccess) {
            if (err) {
                char owner[96] = {0};
                if (openResult == kIOReturnExclusiveAccess &&
                    cusbat_exclusive_owner(vendorID, productID, -1, owner, sizeof(owner)) > 0) {
                    snprintf(err, errLen, "模块已被 %s 独占；退出该程序后再试", owner);
                } else if (openResult == kIOReturnExclusiveAccess) {
                    snprintf(err, errLen, "模块已被其它程序独占；退出占用它的程序后再试");
                } else if (is_stuck_usb_error(openResult)) {
                    snprintf(err, errLen, "%s（0x%08x）", stuck_usb_sentence(), openResult);
                } else {
                    snprintf(err, errLen, "打开 USB 设备 %04x:%04x 失败（0x%08x）",
                             vendorID, productID, openResult);
                }
            }
            (*device)->Release(device);
            IOObjectRelease(service);
            continue;
        }

        session = open_interface_on_device(device, service, vendorID, productID, interfaceNumber,
                                           endpointIn, endpointOut, err, errLen);
        if (session == NULL) {
            (*device)->USBDeviceClose(device);
            (*device)->Release(device);
            IOObjectRelease(service);
            continue;
        }
        break;
    }

    IOObjectRelease(iterator);
    if (session == NULL && err != NULL && err[0] == '\0') {
        snprintf(err, errLen, "未找到 USB 设备 %04x:%04x", vendorID, productID);
    }
    return session;
}

int cusbat_write(void *handle, const unsigned char *data, int length, int timeoutMs)
{
    struct cusbat_session *session = handle;
    if (session == NULL) {
        return CUSBAT_ERR_NOT_OPEN;
    }
    if (timeoutMs <= 0) {
        timeoutMs = CUSBAT_DEFAULT_TIMEOUT_MS;
    }
    IOReturn result = (*session->interface)->WritePipeTO(session->interface, session->pipeOut,
                                                         (void *)data, (UInt32)length,
                                                         (UInt32)timeoutMs, (UInt32)timeoutMs);
    if (result != kIOReturnSuccess) {
        set_error(session, "USB 写入失败（0x%08x）", result);
        return CUSBAT_ERR_WRITE;
    }
    return CUSBAT_OK;
}

int cusbat_read(void *handle, unsigned char *buffer, int length, int timeoutMs)
{
    struct cusbat_session *session = handle;
    if (session == NULL) {
        return CUSBAT_ERR_NOT_OPEN;
    }
    if (timeoutMs <= 0) {
        timeoutMs = CUSBAT_DEFAULT_TIMEOUT_MS;
    }
    UInt32 readLength = (UInt32)length;
    IOReturn result = (*session->interface)->ReadPipeTO(session->interface, session->pipeIn,
                                                        buffer, &readLength,
                                                        (UInt32)timeoutMs, (UInt32)timeoutMs);
    /* kIOUSBTransactionTimeout（0xe0004051）和 kIOReturnTimeout 是两回事：
       前者是 USB 层这一笔事务超时，后者是 IOKit 的通用超时。少了前半句，
       一次普通的读超时会被报成「USB 读取失败（0xe0004051）」，读起来像是
       线断了或者模块坏了，实际只是模块这一次答得慢。 */
    if (result == kIOReturnTimeout || result == kIOReturnAborted ||
        result == kIOUSBTransactionTimeout) {
        return CUSBAT_ERR_TIMEOUT;
    }
    if (result != kIOReturnSuccess) {
        set_error(session, "USB 读取失败（0x%08x）", result);
        return CUSBAT_ERR_READ;
    }
    return (int)readLength;
}

const char *cusbat_last_error(void *handle)
{
    struct cusbat_session *session = handle;
    if (session == NULL) {
        return "";
    }
    return session->lastError;
}

void cusbat_close(void *handle)
{
    struct cusbat_session *session = handle;
    if (session == NULL) {
        return;
    }
    if (session->interface != NULL) {
        (*session->interface)->USBInterfaceClose(session->interface);
        (*session->interface)->Release(session->interface);
    }
    if (session->interfaceService != MACH_PORT_NULL) {
        IOObjectRelease(session->interfaceService);
    }
    if (session->device != NULL) {
        (*session->device)->USBDeviceClose(session->device);
        (*session->device)->Release(session->device);
    }
    if (session->deviceService != MACH_PORT_NULL) {
        IOObjectRelease(session->deviceService);
    }
    free(session);
}

/* 探测之前先解除「短信正文输入」状态。
 *
 * `AT+CMGS=…` 之后模块回一个 `>`，在收到 Ctrl-Z 之前它把随后的每个字节都
 * 当短信正文 —— 包括我们发过去的 `AT`。于是一次中途失败的发送（USB 超时
 * 是最常见的那种）会让这个端口「看起来死了」：再发什么都换不到 OK，直到
 * 模块断电。ESC 是那个提示符的正当出口，模块会回一行 ERROR；健康端口上
 * 它什么也不影响，所以每次打开都发一遍，不判断。
 *
 * 这一条是给交付兜底的：客人那边只要中过一次招，模块就得拔下来重新插，
 * 而他会以为是自己把模块弄坏了。 */
static void leave_data_entry(void *session)
{
    unsigned char escape = 0x1B;
    unsigned char scratch[256];
    (void)cusbat_write(session, &escape, 1, 300);
    for (int attempt = 0; attempt < 4; attempt++) {
        int read = cusbat_read(session, scratch, sizeof(scratch), 150);
        if (read == CUSBAT_ERR_TIMEOUT || read <= 0) {
            break;
        }
    }
}

static int probe_session(void *session, char *out, size_t outLen)
{
    const unsigned char command[] = { 'A', 'T', '\r' };
    leave_data_entry(session);
    if (cusbat_write(session, command, 3, 900) != CUSBAT_OK) {
        return 0;
    }

    size_t used = 0;
    if (out != NULL && outLen > 0) {
        out[0] = '\0';
    }
    for (int attempt = 0; attempt < 8; attempt++) {
        unsigned char buffer[256];
        int read = cusbat_read(session, buffer, sizeof(buffer), 400);
        if (read == CUSBAT_ERR_TIMEOUT) {
            break;
        }
        if (read <= 0) {
            break;
        }
        if (out != NULL && used + (size_t)read + 1 < outLen) {
            memcpy(out + used, buffer, (size_t)read);
            used += (size_t)read;
            out[used] = '\0';
        }
        if (memmem(buffer, (size_t)read, "OK", 2) != NULL) {
            return 1;
        }
    }

    if (out == NULL) {
        return 0;
    }
    return strstr(out, "OK") != NULL ? 1 : 0;
}

/* --------------------- 接口级直连通道（设备级兜底） --------------------- */

/* 设备级句柄是所有进程共用的一道闸门：任何一个程序把它攥住，或者上一次没退干
   净的自己把它攥坏，`USBDeviceOpen` 就会一直失败 —— 哪怕模块和线都是好的。
   接口级句柄走的是另一条路：只要那个接口本身没被别人独占就能打开，而且不占
   设备级闸门，所以浏览器之类的程序再开着也不挡它。

   代价是这条通道读不到配置描述符（描述符要从设备级句柄取），端点只能试出来：
   AT 口是一对「批量出 + 批量入」，多出来的那个入端点用 AT 自己问一句就能分辨。 */

#define CUSBAT_MAX_BULK_PIPES 4

static io_service_t copy_interface_service(int vendorID, int productID, int interfaceNumber)
{
    CFMutableDictionaryRef matching = IOServiceMatching("IOUSBInterface");
    if (matching == NULL) {
        return MACH_PORT_NULL;
    }
    io_iterator_t iterator = MACH_PORT_NULL;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) != KERN_SUCCESS) {
        return MACH_PORT_NULL;
    }

    io_service_t found = MACH_PORT_NULL;
    io_service_t service = MACH_PORT_NULL;
    while ((service = IOIteratorNext(iterator)) != MACH_PORT_NULL) {
        if (found != MACH_PORT_NULL ||
            cf_number_to_byte(service, CFSTR("bInterfaceNumber")) != (unsigned char)interfaceNumber) {
            IOObjectRelease(service);
            continue;
        }
        /* VID/PID 只挂在设备节点上，接口节点自己不带，所以往上一层取。 */
        io_registry_entry_t parent = MACH_PORT_NULL;
        int parentVendor = -1;
        int parentProduct = -1;
        if (IORegistryEntryGetParentEntry(service, kIOServicePlane, &parent) == KERN_SUCCESS) {
            parentVendor = cf_number_to_int(parent, CFSTR("idVendor"));
            parentProduct = cf_number_to_int(parent, CFSTR("idProduct"));
            IOObjectRelease(parent);
        }
        if (parentVendor == vendorID && parentProduct == productID) {
            found = service;
        } else {
            IOObjectRelease(service);
        }
    }
    IOObjectRelease(iterator);
    return found;
}

static void bulk_pipes_of(IOUSBInterfaceInterface500 **interface,
                          UInt8 *inRefs, unsigned char *inAddrs, int *inCount,
                          UInt8 *outRefs, unsigned char *outAddrs, int *outCount)
{
    *inCount = 0;
    *outCount = 0;
    UInt8 pipeCount = 0;
    if ((*interface)->GetNumEndpoints(interface, &pipeCount) != kIOReturnSuccess) {
        return;
    }
    for (UInt8 index = 1; index <= pipeCount; index++) {
        UInt8 direction = 0;
        UInt8 number = 0;
        UInt8 transferType = 0;
        UInt8 interval = 0;
        UInt16 maxPacketSize = 0;
        if ((*interface)->GetPipeProperties(interface, index, &direction, &number,
                                            &transferType, &maxPacketSize, &interval) != kIOReturnSuccess) {
            continue;
        }
        if (transferType != kUSBBulk) {
            continue;
        }
        unsigned char address = (unsigned char)((direction == kUSBIn ? 0x80 : 0x00) | number);
        if (direction == kUSBIn) {
            if (*inCount < CUSBAT_MAX_BULK_PIPES) {
                inRefs[*inCount] = index;
                inAddrs[*inCount] = address;
                (*inCount)++;
            }
        } else if (*outCount < CUSBAT_MAX_BULK_PIPES) {
            outRefs[*outCount] = index;
            outAddrs[*outCount] = address;
            (*outCount)++;
        }
    }
}

/* 只有厂商自定义接口可能是 AT 口。ECM(0x02) 和音频(0x01) 由 macOS 自己的驱
   动占着，去开它们只会换来一句「被 AppleUSBECMControl 占用」，那是客户永远
   退不掉的东西，不该出现在报错里。 */
static int vendor_interface_numbers(int vendorID, int productID, int *out, int maxCount)
{
    CFMutableDictionaryRef matching = IOServiceMatching("IOUSBInterface");
    if (matching == NULL) {
        return 0;
    }
    io_iterator_t iterator = MACH_PORT_NULL;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) != KERN_SUCCESS) {
        return 0;
    }

    int count = 0;
    io_service_t service = MACH_PORT_NULL;
    while ((service = IOIteratorNext(iterator)) != MACH_PORT_NULL) {
        int number = cf_number_to_byte(service, CFSTR("bInterfaceNumber"));
        int interfaceClass = cf_number_to_byte(service, CFSTR("bInterfaceClass"));
        io_registry_entry_t parent = MACH_PORT_NULL;
        int parentVendor = -1;
        int parentProduct = -1;
        if (IORegistryEntryGetParentEntry(service, kIOServicePlane, &parent) == KERN_SUCCESS) {
            parentVendor = cf_number_to_int(parent, CFSTR("idVendor"));
            parentProduct = cf_number_to_int(parent, CFSTR("idProduct"));
            IOObjectRelease(parent);
        }
        IOObjectRelease(service);

        if (interfaceClass != 0xFF || parentVendor != vendorID || parentProduct != productID) {
            continue;
        }
        if (count >= maxCount) {
            continue;
        }
        int position = count;
        while (position > 0 && out[position - 1] > number) {
            out[position] = out[position - 1];
            position--;
        }
        out[position] = number;
        count++;
    }
    IOObjectRelease(iterator);
    return count;
}

static void *open_direct_interface(int vendorID, int productID, int interfaceNumber,
                                   cusbat_open_info *info, char *err, size_t errLen)
{
    io_service_t service = copy_interface_service(vendorID, productID, interfaceNumber);
    if (service == MACH_PORT_NULL) {
        if (err) snprintf(err, errLen, "USB 接口 %d 不存在", interfaceNumber);
        return NULL;
    }

    IOCFPlugInInterface **plugin = NULL;
    SInt32 score = 0;
    IOReturn created = IOCreatePlugInInterfaceForService(service, kIOUSBInterfaceUserClientTypeID,
                                                         kIOCFPlugInInterfaceID, &plugin, &score);
    if (created != kIOReturnSuccess) {
        IOObjectRelease(service);
        if (err) {
            if (is_stuck_usb_error(created)) {
                snprintf(err, errLen, "%s（0x%08x）", stuck_usb_sentence(), created);
            } else {
                snprintf(err, errLen, "接口 %d 的 USB 通道创建失败（0x%08x）", interfaceNumber, created);
            }
        }
        return NULL;
    }
    IOUSBInterfaceInterface500 **interface = NULL;
    (*plugin)->QueryInterface(plugin, CFUUIDGetUUIDBytes(kIOUSBInterfaceInterfaceID500), (LPVOID *)&interface);
    (*plugin)->Release(plugin);
    if (interface == NULL) {
        IOObjectRelease(service);
        if (err) snprintf(err, errLen, "接口 %d 不支持 IOUSBInterfaceInterface", interfaceNumber);
        return NULL;
    }

    IOReturn opened = (*interface)->USBInterfaceOpen(interface);
    if (opened != kIOReturnSuccess) {
        (*interface)->Release(interface);
        char owner[96] = {0};
        if (opened == kIOReturnExclusiveAccess &&
            cusbat_exclusive_owner(vendorID, productID, interfaceNumber, owner, sizeof(owner)) > 0) {
            if (err) snprintf(err, errLen, "接口 %d 正被 %s 占用；退出该程序后再试", interfaceNumber, owner);
        } else if (opened == kIOReturnExclusiveAccess) {
            if (err) snprintf(err, errLen, "接口 %d 已被其它程序独占；退出占用它的程序后再试", interfaceNumber);
        } else if (err) {
            if (is_stuck_usb_error(opened)) {
                snprintf(err, errLen, "%s（0x%08x）", stuck_usb_sentence(), opened);
            } else {
                snprintf(err, errLen, "接口 %d 占用失败（0x%08x）", interfaceNumber, opened);
            }
        }
        IOObjectRelease(service);
        return NULL;
    }

    UInt8 inRefs[CUSBAT_MAX_BULK_PIPES];
    UInt8 outRefs[CUSBAT_MAX_BULK_PIPES];
    unsigned char inAddrs[CUSBAT_MAX_BULK_PIPES];
    unsigned char outAddrs[CUSBAT_MAX_BULK_PIPES];
    int inCount = 0;
    int outCount = 0;
    bulk_pipes_of(interface, inRefs, inAddrs, &inCount, outRefs, outAddrs, &outCount);

    void *result = NULL;
    for (int outIndex = 0; outIndex < outCount && result == NULL; outIndex++) {
        for (int inIndex = 0; inIndex < inCount; inIndex++) {
            struct cusbat_session *trial = make_session(interface, service, NULL, MACH_PORT_NULL,
                                                        inRefs[inIndex], outRefs[outIndex]);
            if (trial == NULL) {
                break;
            }
            char probe[64] = {0};
            if (probe_session(trial, probe, sizeof(probe))) {
                if (info != NULL) {
                    info->interfaceNumber = interfaceNumber;
                    info->endpointIn = inAddrs[inIndex];
                    info->endpointOut = outAddrs[outIndex];
                    info->interfaceOnly = 1;
                    snprintf(info->probeResponse, sizeof(info->probeResponse), "%s", probe);
                }
                if (err) {
                    err[0] = '\0';
                }
                result = trial;
                break;
            }
            /* 这一对端点没人应：句柄留给下一对继续用，只回收结构体本身。 */
            trial->interface = NULL;
            trial->interfaceService = MACH_PORT_NULL;
            cusbat_close(trial);
        }
    }

    if (result == NULL) {
        (*interface)->USBInterfaceClose(interface);
        (*interface)->Release(interface);
        IOObjectRelease(service);
        if (err) snprintf(err, errLen, "接口 %d 上的批量端点没有 AT 应答", interfaceNumber);
    }
    return result;
}

static void *cusbat_open_direct(int vendorID, int productID, cusbat_open_info *info,
                                char *err, size_t errLen)
{
    int numbers[16];
    int count = vendor_interface_numbers(vendorID, productID, numbers, 16);
    char firstError[192] = {0};
    for (int index = 0; index < count; index++) {
        char oneError[192] = {0};
        void *session = open_direct_interface(vendorID, productID, numbers[index], info,
                                              oneError, sizeof(oneError));
        if (session != NULL) {
            return session;
        }
        if (firstError[0] == '\0') {
            snprintf(firstError, sizeof(firstError), "%s", oneError);
        }
    }
    if (err != NULL) {
        snprintf(err, errLen, "%s", firstError[0] != '\0' ? firstError : "没有可用的 AT 接口");
    }
    return NULL;
}

void *cusbat_open_auto(int vendorID, int productID, cusbat_open_info *info,
                       char *err, size_t errLen)
{
    cusbat_candidate candidates[16];
    int count = cusbat_candidates(vendorID, productID, candidates, 16);
    if (count < 0) {
        if (err) snprintf(err, errLen, "USB 枚举失败（%d）", count);
        return NULL;
    }
    if (count == 0) {
        /* 设备级通道走不通了（描述符读不到 = USBDeviceOpen 没成）。先试接口
           级直连：模块和线都正常、只是设备级闸门被别的程序攥住或被系统卡住
           时，这条路仍然通。 */
        char directError[192] = {0};
        void *direct = cusbat_open_direct(vendorID, productID, info, directError, sizeof(directError));
        if (direct != NULL) {
            if (err) {
                err[0] = '\0';
            }
            return direct;
        }
        /* "No candidates" and "no device" are different failures, and saying
           the wrong one sends the reader looking for a cable problem that is
           not there. cusbat_present is a read-only check, so it can still tell
           the two apart when the descriptor itself was unreadable. */
        if (err) {
            if (directError[0] != '\0') {
                snprintf(err, errLen, "%s", directError);
            } else if (cusbat_present(vendorID, productID) > 0) {
                snprintf(err, errLen,
                         "模块已连接，但读不到它的 USB 接口描述（%04x:%04x）；拔掉数据线等 5 秒再插回即可恢复",
                         vendorID, productID);
            } else {
                snprintf(err, errLen, "未找到 USB 设备 %04x:%04x", vendorID, productID);
            }
        }
        return NULL;
    }

    char last[192] = {0};
    /* A held interface is the interesting failure: it says the module is fine
       and something else is using it. Probe failures on the remaining
       interfaces are noise next to that, so they must not overwrite it.
       But only a vendor-class interface can be the AT port: the ECM and audio
       interfaces are held by macOS's own drivers on purpose, and naming those
       tells the customer to quit something he cannot quit. */
    char busy[192] = {0};
    char first[192] = {0};
    for (int index = 0; index < count; index++) {
        char openError[192] = {0};
        void *session = cusbat_open(vendorID, productID,
                                    candidates[index].interfaceNumber,
                                    candidates[index].endpointIn,
                                    candidates[index].endpointOut,
                                    openError, sizeof(openError));
        if (session == NULL) {
            if (busy[0] == '\0' && candidates[index].interfaceClass == 0xFF) {
                char owner[96] = {0};
                if (cusbat_exclusive_owner(vendorID, productID, candidates[index].interfaceNumber,
                                           owner, sizeof(owner)) > 0) {
                    snprintf(busy, sizeof(busy), "接口 %d 正被 %s 占用；退出该程序后再试",
                             candidates[index].interfaceNumber, owner);
                }
            }
            snprintf(last, sizeof(last), "接口 %d: %s", candidates[index].interfaceNumber, openError);
            if (first[0] == '\0') {
                snprintf(first, sizeof(first), "%s", last);
            }
            continue;
        }

        char probe[64] = {0};
        if (probe_session(session, probe, sizeof(probe))) {
            if (info != NULL) {
                info->interfaceNumber = candidates[index].interfaceNumber;
                info->endpointIn = candidates[index].endpointIn;
                info->endpointOut = candidates[index].endpointOut;
                snprintf(info->probeResponse, sizeof(info->probeResponse), "%s", probe);
            }
            if (err) {
                err[0] = '\0';
            }
            return session;
        }
        cusbat_close(session);
        snprintf(last, sizeof(last), "接口 %d: AT 探测无 OK 应答", candidates[index].interfaceNumber);
        if (first[0] == '\0') {
            snprintf(first, sizeof(first), "%s", last);
        }
    }

    if (err) {
        /* 先说第一个候选接口（按号排下来就是 AT 口）到底怎么了 —— 那是客
           人能动手的地方；真被人占着的厂商接口再补在后面。以前反过来，
           于是一个读超时会被报成「接口 5 正被 AppleUSBECMData 占用」，而
           那个驱动是 macOS 自带的，客户永远退不掉。 */
        const char *detail = first[0] != '\0' ? first : last;
        if (busy[0] != '\0' && detail[0] != '\0') {
            snprintf(err, errLen, "%s；%s", detail, busy);
        } else if (busy[0] != '\0') {
            snprintf(err, errLen, "%s", busy);
        } else {
            snprintf(err, errLen, "%s", detail[0] != '\0' ? detail : "没有可用的 AT 接口");
        }
    }
    return NULL;
}
