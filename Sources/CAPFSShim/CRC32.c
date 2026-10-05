#include "CAPFSShim.h"
#include <pthread.h>

static uint32_t table[256];
static pthread_once_t once = PTHREAD_ONCE_INIT;
static void initialize(void) {
    for (unsigned int i = 0; i < 256; ++i) {
        uint32_t value = i;
        for (int bit = 0; bit < 8; ++bit)
            value = (value >> 1) ^ ((value & 1) ? 0xedb88320u : 0);
        table[i] = value;
    }
}
uint32_t apfs_crc32(uint32_t previous, const void *bytes, size_t length) {
    pthread_once(&once, initialize);
    const unsigned char *cursor = bytes;
    uint32_t value = previous ^ 0xffffffffu;
    for (size_t i = 0; i < length; ++i) value = table[(value ^ cursor[i]) & 255] ^ (value >> 8);
    return value ^ 0xffffffffu;
}
