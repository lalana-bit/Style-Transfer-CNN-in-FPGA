#ifndef CNN_STYLE_BANKS_H
#define CNN_STYLE_BANKS_H
/* 所有风格复用原计算核心；显式地址表保留既有 Flash 段。 */
#define WEIGHT_BYTES 63296u
#define STYLE_COUNT 4u
static const uint32_t style_weight_crc[STYLE_COUNT] = {
    0x77df0b16u,
    0xca31c1aau,
    0x70aeb8d4u,
    0xda3772f9u,

};
static const uint32_t style_affine_crc[STYLE_COUNT] = {
    0x0c19a040u,
    0x3ec80b28u,
    0x8bb49bfeu,
    0x966e305fu,
};
static const uint32_t style_weight_offset[STYLE_COUNT] = {
    0x00000000u,
    0x00040000u,
    0x00060000u,
    0x00080000u,
};
static const uint32_t style_affine_offset[STYLE_COUNT] = {
    0x00020000u,
    0x00050000u,
    0x00070000u,
    0x00090000u,
};
static const char *const style_labels[STYLE_COUNT] = {
    "STYLE=STARRY_E012_IN15_TRAINED\r\n",
    "STYLE=CUBIST_IN15_TRAINED\r\n",
    "STYLE=BLUE_GLASS_IN15_TRAINED\r\n",
    "STYLE=MOSAIC_TEXTURE_V2_IN15_TRAINED\r\n",
};
#endif
