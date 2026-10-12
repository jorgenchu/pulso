#ifndef CPULSO_H
#define CPULSO_H

#include <stdint.h>
#include <mach/kern_return.h>

#ifdef __cplusplus
extern "C" {
#endif

// MARK: - SMC

/// Opens a user client on AppleSMC. `connection` is an io_connect_t.
kern_return_t PulsoSMCOpen(uint32_t *connection);
void PulsoSMCClose(uint32_t connection);

/// Looks up the type (FourCC) and size in bytes of a key.
kern_return_t PulsoSMCReadKeyInfo(uint32_t connection, uint32_t key, uint32_t *dataType, uint32_t *dataSize);

/// Reads the raw value of a key. `bytes` must have room for 32 bytes.
kern_return_t PulsoSMCReadBytes(uint32_t connection, uint32_t key, uint32_t dataSize, uint8_t *bytes);

/// Writes the raw value of a key. `dataSize` must be the key's own size. Fails with
/// kIOReturnNotPrivileged unless the caller is root.
kern_return_t PulsoSMCWriteBytes(uint32_t connection, uint32_t key, uint32_t dataSize, const uint8_t *bytes);

/// Returns the key stored at `index` (0 ..< value of the `#KEY` key).
kern_return_t PulsoSMCKeyAtIndex(uint32_t connection, uint32_t index, uint32_t *key);

// MARK: - HID sensors

typedef struct {
    char name[64];
    double value;
} PulsoHIDReading;

/// Reads every HID sensor service matching the usage page/usage pair and
/// returns how many readings were written to `out` (at most `capacity`).
int PulsoHIDReadSensors(int32_t usagePage, int32_t usage, int64_t eventType, PulsoHIDReading *out, int capacity);

// MARK: - Network interface counters

typedef struct {
    char name[16];
    uint64_t bytesIn;
    uint64_t bytesOut;
    uint32_t flags;
    uint8_t type;
} PulsoInterfaceCounters;

/// Reads the 64-bit traffic counters of every interface and returns how many
/// entries were written to `out` (at most `capacity`).
int PulsoReadInterfaceCounters(PulsoInterfaceCounters *out, int capacity);

#ifdef __cplusplus
}
#endif

#endif
