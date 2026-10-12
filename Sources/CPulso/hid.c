#include "CPulso.h"

#include <CoreFoundation/CoreFoundation.h>

// Apple Silicon exposes its thermal sensors as HID services. Reading them needs
// these IOKit entry points, which are exported but absent from the public headers.
typedef struct __IOHIDEventSystemClient *IOHIDEventSystemClientRef;
typedef struct __IOHIDServiceClient *IOHIDServiceClientRef;
typedef struct __IOHIDEvent *IOHIDEventRef;

extern IOHIDEventSystemClientRef IOHIDEventSystemClientCreate(CFAllocatorRef allocator);
extern int IOHIDEventSystemClientSetMatching(IOHIDEventSystemClientRef client, CFDictionaryRef match);
extern CFArrayRef IOHIDEventSystemClientCopyServices(IOHIDEventSystemClientRef client);
extern CFTypeRef IOHIDServiceClientCopyProperty(IOHIDServiceClientRef service, CFStringRef key);
extern IOHIDEventRef IOHIDServiceClientCopyEvent(IOHIDServiceClientRef service, int64_t type, int32_t options, int64_t timestamp);
extern double IOHIDEventGetFloatValue(IOHIDEventRef event, int32_t field);

// Not thread-safe: callers must serialise access (the sampling engine does).
int PulsoHIDReadSensors(int32_t usagePage, int32_t usage, int64_t eventType, PulsoHIDReading *out, int capacity) {
    static IOHIDEventSystemClientRef client = NULL;
    if (client == NULL) client = IOHIDEventSystemClientCreate(kCFAllocatorDefault);
    if (client == NULL || out == NULL || capacity <= 0) return 0;

    CFNumberRef page = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &usagePage);
    CFNumberRef use = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &usage);
    const void *keys[] = { CFSTR("PrimaryUsagePage"), CFSTR("PrimaryUsage") };
    const void *values[] = { page, use };
    CFDictionaryRef match = CFDictionaryCreate(kCFAllocatorDefault, keys, values, 2,
                                               &kCFTypeDictionaryKeyCallBacks,
                                               &kCFTypeDictionaryValueCallBacks);
    IOHIDEventSystemClientSetMatching(client, match);
    CFRelease(match);
    CFRelease(page);
    CFRelease(use);

    CFArrayRef services = IOHIDEventSystemClientCopyServices(client);
    if (services == NULL) return 0;

    int written = 0;
    CFIndex count = CFArrayGetCount(services);
    for (CFIndex i = 0; i < count && written < capacity; i++) {
        IOHIDServiceClientRef service = (IOHIDServiceClientRef)CFArrayGetValueAtIndex(services, i);
        CFTypeRef name = IOHIDServiceClientCopyProperty(service, CFSTR("Product"));
        if (name == NULL) continue;
        if (CFGetTypeID(name) == CFStringGetTypeID()) {
            IOHIDEventRef event = IOHIDServiceClientCopyEvent(service, eventType, 0, 0);
            if (event != NULL) {
                PulsoHIDReading *reading = &out[written];
                if (CFStringGetCString((CFStringRef)name, reading->name, sizeof(reading->name), kCFStringEncodingUTF8)) {
                    reading->value = IOHIDEventGetFloatValue(event, (int32_t)(eventType << 16));
                    written++;
                }
                CFRelease(event);
            }
        }
        CFRelease(name);
    }
    CFRelease(services);
    return written;
}
