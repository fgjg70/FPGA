#ifndef DIGIT_PLATFORM_H
#define DIGIT_PLATFORM_H

#include <stdint.h>

#define REGISTER(address) (*(volatile uint32_t *)(address))
#define CYCLE REGISTER(0xA0000008u)
#define KEY_EVENTS REGISTER(0xA0000080u)
#define KEY_LEVELS REGISTER(0xA0000084u)
#define I2C_OUTPUT REGISTER(0xA0000088u)
#define I2C_INPUT REGISTER(0xA000008Cu)
#define DISPLAY_STATE REGISTER(0xA0000090u)
#define DISPLAY_SOFTWARE REGISTER(0xA0000094u)
#define DISPLAY_HARDWARE REGISTER(0xA0000098u)
#define DISPLAY_COMMIT REGISTER(0xA00000A0u)
#define DISPLAY_IMAGE ((volatile uint32_t *)0xA0000800u)

typedef struct {
    uint8_t pin[4];
    uint32_t mode;
    uint32_t unlock_ms;
    uint32_t generation;
} configuration_t;

void app_service(void);
void platform_initialize(configuration_t *configuration);
int platform_save(configuration_t *configuration);
uint32_t platform_status(void);
uint16_t crc_update(uint16_t crc, uint8_t value);

#endif
