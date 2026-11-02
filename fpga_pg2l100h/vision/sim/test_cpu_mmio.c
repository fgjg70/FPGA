#include <stdint.h>

static volatile uint32_t *const device = (volatile uint32_t *)0xa1000000u;
static volatile uint32_t scratch[8];

int main(void)
{
    uint32_t iteration;
    uint32_t expected;
    uint32_t observed;
    uint32_t checksum = 0;
    for (iteration = 0; iteration < 512; iteration++) {
        expected = iteration * 2654435761u + 0x13579bdfu;
        scratch[iteration & 7u] = expected ^ 0xa5a5a5a5u;
        device[0] = expected;
        observed = device[0];
        if (observed != expected || scratch[iteration & 7u] != (observed ^ 0xa5a5a5a5u)) {
            device[4] = 0xbad00001u;
            return 1;
        }
        ((volatile uint8_t *)device)[1] = (uint8_t)(iteration ^ 0x5au);
        expected = (expected & 0xffff00ffu) | (((iteration ^ 0x5au) & 255u) << 8);
        observed = device[0];
        if (observed != expected || device[1] != iteration + 1u) {
            device[4] = 0xbad00002u;
            return 2;
        }
        checksum ^= observed + scratch[iteration & 7u];
    }
    device[3] = checksum;
    device[4] = 0x600dc0deu;
    return 0;
}
