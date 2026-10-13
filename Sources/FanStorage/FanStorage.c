#include "FanStorage.h"
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/storage/nvme/NVMeSMARTLibExternal.h>

_Static_assert(sizeof(NVMeSMARTData) == 512, "NVMe SMART data must occupy 512 bytes");

int32_t FanStorageReadNVMeTemperature(uint32_t service, double *temperature) {
    if (!service || !temperature) return kIOReturnBadArgument;

    IOCFPlugInInterface **plugin = NULL;
    IONVMeSMARTInterface **smart = NULL;
    SInt32 score = 0;
    IOReturn result = IOCreatePlugInInterfaceForService(service, kIONVMeSMARTUserClientTypeID,
                                                      kIOCFPlugInInterfaceID, &plugin, &score);
    if (result == kIOReturnSuccess && plugin) {
        HRESULT query = (*plugin)->QueryInterface(plugin, CFUUIDGetUUIDBytes(kIONVMeSMARTInterfaceID),
                                                 (LPVOID *)&smart);
        if (query == S_OK && smart) {
            NVMeSMARTData data = {0};
            result = (*smart)->SMARTReadData(smart, &data);
            if (result == kIOReturnSuccess) {
                *temperature = (double)CFSwapInt16LittleToHost(data.TEMPERATURE) - 273.15;
            }
        } else {
            result = kIOReturnUnsupported;
        }
    } else if (result == kIOReturnSuccess) {
        result = kIOReturnNoResources;
    }
    if (smart) (*smart)->Release(smart);
    if (plugin) IODestroyPlugInInterface(plugin);
    return result;
}
