#include "CPulso.h"

#include <IOKit/IOKitLib.h>
#include <string.h>

enum {
    kSMCUserClientMethod = 2,
    kSMCCommandReadBytes = 5,
    kSMCCommandWriteBytes = 6,
    kSMCCommandReadIndex = 8,
    kSMCCommandReadKeyInfo = 9,
};

typedef struct {
    uint8_t major;
    uint8_t minor;
    uint8_t build;
    uint8_t reserved;
    uint16_t release;
} SMCVersion;

typedef struct {
    uint16_t version;
    uint16_t length;
    uint32_t cpuPLimit;
    uint32_t gpuPLimit;
    uint32_t memPLimit;
} SMCPLimitData;

typedef struct {
    uint32_t dataSize;
    uint32_t dataType;
    uint8_t dataAttributes;
} SMCKeyInfo;

// Must match the kernel's SMCParamStruct byte for byte.
typedef struct {
    uint32_t key;
    SMCVersion vers;
    SMCPLimitData pLimitData;
    SMCKeyInfo keyInfo;
    uint8_t result;
    uint8_t status;
    uint8_t data8;
    uint32_t data32;
    uint8_t bytes[32];
} SMCParamStruct;

_Static_assert(sizeof(SMCParamStruct) == 80, "SMCParamStruct layout drifted from the kernel's");

static kern_return_t SMCCall(uint32_t connection, SMCParamStruct *input, SMCParamStruct *output) {
    size_t outputSize = sizeof(SMCParamStruct);
    kern_return_t result = IOConnectCallStructMethod(connection, kSMCUserClientMethod,
                                                     input, sizeof(SMCParamStruct),
                                                     output, &outputSize);
    if (result != KERN_SUCCESS) return result;
    // The SMC reports per-key failures (e.g. 0x84, key not found) in-band.
    return output->result == 0 ? KERN_SUCCESS : kIOReturnNotFound;
}

kern_return_t PulsoSMCOpen(uint32_t *connection) {
    io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"));
    if (service == IO_OBJECT_NULL) return kIOReturnNotFound;
    io_connect_t opened = IO_OBJECT_NULL;
    kern_return_t result = IOServiceOpen(service, mach_task_self(), 0, &opened);
    IOObjectRelease(service);
    if (result == KERN_SUCCESS) *connection = opened;
    return result;
}

void PulsoSMCClose(uint32_t connection) {
    if (connection != IO_OBJECT_NULL) IOServiceClose(connection);
}

kern_return_t PulsoSMCReadKeyInfo(uint32_t connection, uint32_t key, uint32_t *dataType, uint32_t *dataSize) {
    SMCParamStruct input = {0}, output = {0};
    input.key = key;
    input.data8 = kSMCCommandReadKeyInfo;
    kern_return_t result = SMCCall(connection, &input, &output);
    if (result != KERN_SUCCESS) return result;
    *dataType = output.keyInfo.dataType;
    *dataSize = output.keyInfo.dataSize;
    return KERN_SUCCESS;
}

kern_return_t PulsoSMCReadBytes(uint32_t connection, uint32_t key, uint32_t dataSize, uint8_t *bytes) {
    SMCParamStruct input = {0}, output = {0};
    input.key = key;
    input.keyInfo.dataSize = dataSize;
    input.data8 = kSMCCommandReadBytes;
    kern_return_t result = SMCCall(connection, &input, &output);
    if (result != KERN_SUCCESS) return result;
    memcpy(bytes, output.bytes, sizeof(output.bytes));
    return KERN_SUCCESS;
}

kern_return_t PulsoSMCWriteBytes(uint32_t connection, uint32_t key, uint32_t dataSize, const uint8_t *bytes) {
    SMCParamStruct input = {0}, output = {0};
    if (dataSize == 0 || dataSize > sizeof(input.bytes)) return kIOReturnBadArgument;
    input.key = key;
    input.keyInfo.dataSize = dataSize;
    input.data8 = kSMCCommandWriteBytes;
    memcpy(input.bytes, bytes, dataSize);
    return SMCCall(connection, &input, &output);
}

kern_return_t PulsoSMCKeyAtIndex(uint32_t connection, uint32_t index, uint32_t *key) {
    SMCParamStruct input = {0}, output = {0};
    input.data8 = kSMCCommandReadIndex;
    input.data32 = index;
    kern_return_t result = SMCCall(connection, &input, &output);
    if (result != KERN_SUCCESS) return result;
    *key = output.key;
    return KERN_SUCCESS;
}
