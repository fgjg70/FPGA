#ifndef OBJECT_DECODE_H
#define OBJECT_DECODE_H

#include <stdint.h>

typedef struct {
    int left;
    int top;
    int right;
    int bottom;
    int category;
    int score;
} object_detection;

static int object_clip(int value, int lower, int upper) {
    return value < lower ? lower : value > upper ? upper : value;
}

static int object_overlap(const object_detection *first, const object_detection *second) {
    int left = first->left > second->left ? first->left : second->left;
    int top = first->top > second->top ? first->top : second->top;
    int right = first->right < second->right ? first->right : second->right;
    int bottom = first->bottom < second->bottom ? first->bottom : second->bottom;
    int intersection = object_clip(right - left, 0, 64) * object_clip(bottom - top, 0, 64);
    int total = (first->right - first->left) * (first->bottom - first->top) +
                (second->right - second->left) * (second->bottom - second->top) - intersection;
    return total > 0 && intersection * 5 >= total * 2;
}

static unsigned object_decode(const int32_t *outputs, int threshold, int margin_threshold, object_detection *kept) {
    object_detection candidates[16];
    unsigned count = 0;
    for (unsigned cell = 0; cell < 16; cell++) {
        const int32_t *values = outputs + cell * 27;
        if (values[0] < threshold) continue;
        int category = 0;
        for (int index = 1; index < 4; index++) if (values[5 + index] > values[5 + category]) category = index;
        int second = INT32_MIN;
        for (int index = 0; index < 4; index++) if (index != category && values[5 + index] > second) second = values[5 + index];
        if ((int64_t)values[5 + category] - second < margin_threshold) continue;
        int center_x = (int)(cell % 4) * 16 + object_clip(values[1], 0, 127) / 8;
        int center_y = (int)(cell / 4) * 16 + object_clip(values[2], 0, 127) / 8;
        int width = object_clip(object_clip(values[3], 0, 128) / 2, 4, 64);
        int height = object_clip(object_clip(values[4], 0, 128) / 2, 4, 64);
        object_detection candidate = {
            object_clip(center_x - width / 2, 0, 63), object_clip(center_y - height / 2, 0, 63),
            object_clip(center_x + width / 2, 0, 63), object_clip(center_y + height / 2, 0, 63), category, values[0]
        };
        if (candidate.bottom <= 8 || candidate.top >= 56) continue;
        candidates[count++] = candidate;
    }
    unsigned accepted = 0;
    while (count && accepted < 4) {
        unsigned best = 0;
        for (unsigned index = 1; index < count; index++) if (candidates[index].score > candidates[best].score) best = index;
        object_detection candidate = candidates[best];
        for (unsigned index = best + 1; index < count; index++) candidates[index - 1] = candidates[index];
        count--;
        int duplicate = 0;
        for (unsigned index = 0; index < accepted; index++) if (object_overlap(&candidate, &kept[index])) duplicate = 1;
        if (!duplicate) kept[accepted++] = candidate;
    }
    return accepted;
}

#endif
