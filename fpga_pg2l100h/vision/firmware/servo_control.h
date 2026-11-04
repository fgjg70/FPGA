#ifndef SERVO_CONTROL_H
#define SERVO_CONTROL_H

typedef struct {
    unsigned state;
    unsigned number;
    unsigned pulse_us;
    unsigned digits;
} servo_parser;

static int servo_receive(servo_parser *parser, unsigned byte, unsigned *number, unsigned *pulse_us) {
    if (!parser->state) {
        if (byte != 's' && byte != 'S') return 0;
        parser->state = 1;
        parser->number = 0;
        parser->pulse_us = 0;
        parser->digits = 0;
        return 1;
    }
    if (byte == '\r' || byte == '\n') {
        int valid = parser->state == 3 && parser->digits &&
                    (parser->pulse_us == 0 || (parser->number && parser->pulse_us >= 1000 && parser->pulse_us <= 2000));
        parser->state = 0;
        if (!valid) return -1;
        *number = parser->number;
        *pulse_us = parser->pulse_us;
        return 2;
    }
    if (parser->state == 1 && byte >= '0' && byte <= '7') {
        parser->number = byte - '0';
        parser->state = 2;
    } else if (parser->state == 2 && byte == '=') {
        parser->state = 3;
    } else if (parser->state == 3 && byte >= '0' && byte <= '9' && parser->digits < 4) {
        parser->pulse_us = parser->pulse_us * 10 + byte - '0';
        parser->digits++;
    } else parser->state = 4;
    return 1;
}

#endif
