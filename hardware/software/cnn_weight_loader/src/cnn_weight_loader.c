/* 用途：初始化摄像头，预载四风格权重，处理按键风格请求和后台IN更新。
 * 原理：Flash仅在启动阶段读取；切换时从DDR选区加载，保留原有排空与CRC协议。
 */
#include <stdint.h>
#include "bsp.h"
#include "spiFlash.h"
#include "cnn_style_banks.h"

#ifndef CNN_FLASH_OFFSET
#define CNN_FLASH_OFFSET 0x00400000u
#endif

#define FLASH_BYTES 0x00800000u /* GD25LQ64: 64 Mbit = 8 MiB. */
#define CHUNK_BYTES 256u
#define TIMEOUT_TICKS (2u * SYSTEM_CLINT_HZ)

#define REG_STATUS         0x00u
#define REG_CONTROL        0x04u
#define REG_TOTAL_BYTES    0x08u
#define REG_DATA32         0x0cu
#define REG_EXPECTED_CRC   0x10u
#define REG_RECEIVED_BYTES 0x14u
#define REG_STYLE_REQUEST  0x18u
#define REG_DDR_BANK       0x30u
#define REG_AFFINE_READ    0x34u
#define REG_AFFINE_DATA    0x40u
#define ST_AFFINE_READY    (1u << 6)
#define CTRL_CACHE        4u
#define AFFINE_BYTES      3200u
#define CACHE_BYTES       (WEIGHT_BYTES + AFFINE_BYTES)
#define ST_CALIB_DONE      (1u << 0)
#define ST_TX_READY        (1u << 1)
#define ST_WRITE_DONE      (1u << 2)
#define ST_PARAMS_READY    (1u << 3)
#define ST_ERROR           (1u << 4)
#define ST_RELOAD_READY    (1u << 5)
#define CTRL_BEGIN         1u
#define CTRL_COMMIT        2u
#define CTRL_QUIESCE       3u

/* Volatile variables are available in the debugger. Stage 8 means success.
 * An unconfigured offset is kept volatile so the loader remains in the ELF.
 */
volatile uint32_t cnn_flash_offset = CNN_FLASH_OFFSET;
volatile uint32_t cnn_boot_stage;
volatile uint32_t cnn_boot_error;
volatile uint32_t cnn_bytes_sent;
volatile uint32_t cnn_image_crc;
volatile uint32_t cnn_active_style;
volatile uint32_t cnn_switch_error;
volatile uint32_t cnn_switch_count;
volatile uint32_t cnn_control_busy = 1u;
volatile uint32_t cnn_runtime_fault;
/* 各槽有效标志在上电预载后保持，运行期不再访问 Flash。 */
static uint32_t cnn_cached_styles;
static uint32_t cnn_read_affine(uint32_t style, uint32_t offset, uint32_t count);
static uint8_t chunk[CHUNK_BYTES] __attribute__((aligned(4)));
static void reg_write(uint32_t offset, uint32_t value);

#ifndef CNN_REG_READ
#define CNN_REG_READ(offset) (*(volatile uint32_t *)(uintptr_t)(IO_APB_SLAVE_0_INPUT + (offset)))
#define CNN_REG_WRITE(offset, value) do { \
    *(volatile uint32_t *)(uintptr_t)(IO_APB_SLAVE_0_INPUT + (offset)) = (value); \
    __asm__ volatile ("fence iorw, iorw" ::: "memory"); \
} while (0)
#endif

static uint32_t reg_read(uint32_t offset)
{
    return CNN_REG_READ(offset);
}

/* Trained E012 IN15 with background refresh; CRCs bind the exact Flash images. */
#include "cnn_in_runtime.h"

static void reg_write(uint32_t offset, uint32_t value)
{
    CNN_REG_WRITE(offset, value);
}

// 启动错误保持在可通过JTAG读取的状态变量中，硬件复位后重新初始化。
static void stop_with_error(uint32_t code)
{
    cnn_boot_error = code;
    cnn_control_busy = 1u;
    for (;;) { __asm__ volatile ("nop"); }
}

#include "camera_init.h"

static uint32_t wait_status(uint32_t mask)
{
    uint32_t start = clint_getTimeLow(BSP_CLINT);
    /* Camera setup and the existing video reset delay can exceed two seconds. */
    uint32_t timeout = (mask & (ST_CALIB_DONE | ST_PARAMS_READY))
                     ? 10u * SYSTEM_CLINT_HZ : TIMEOUT_TICKS;
    for (;;) {
        uint32_t status = reg_read(REG_STATUS);

        if (status & ST_ERROR) return 2u;
        if ((status & mask) == mask) return 0u;
        if ((uint32_t)(clint_getTimeLow(BSP_CLINT) - start) >= timeout)
            return 3u;
    }
}

static uint32_t crc32_update(uint32_t crc, const uint8_t *data, uint32_t count)
{
    for (uint32_t i = 0; i < count; ++i) {
        crc ^= data[i];
        for (uint32_t bit = 0; bit < 8u; ++bit)
            crc = (crc >> 1) ^ ((0u - (crc & 1u)) & 0xedb88320u);
    }
    return crc;
}

static uint32_t style_crc(uint32_t style)
{
    return style_weight_crc[style];
}

static uint32_t style_offset(uint32_t style)
{
    return cnn_flash_offset + style_weight_offset[style];
}

/* 仅循环到已通过上电校验并预载的槽，缺失风格不会阻断切回。 */
static uint32_t next_style(void)
{
    for (uint32_t step = 1u; step < STYLE_COUNT; ++step) {
        uint32_t candidate = (cnn_active_style + step) % STYLE_COUNT;
        if (cnn_cached_styles & (1u << candidate)) return candidate;
    }
    return cnn_active_style;
}

/* Validate Flash BEFORE stopping the current style. Missing/corrupt Candy
 * leaves the previous style running rather than replacing its parameters.
 */
static uint32_t validate_flash(uint32_t style)
{
    uint32_t crc = 0xffffffffu;
    if (style >= STYLE_COUNT || cnn_flash_offset > FLASH_BYTES - WEIGHT_BYTES ||
        style_weight_offset[style] > FLASH_BYTES - WEIGHT_BYTES - cnn_flash_offset ||
        cnn_flash_offset > FLASH_BYTES - AFFINE_BYTES ||
        style_affine_offset[style] > FLASH_BYTES - AFFINE_BYTES - cnn_flash_offset)
        return 0u;
    uint32_t flash_offset = style_offset(style);
    for (uint32_t offset = 0; offset < WEIGHT_BYTES; offset += CHUNK_BYTES) {
        uint32_t count = WEIGHT_BYTES - offset;
        if (count > CHUNK_BYTES) count = CHUNK_BYTES;
        spiFlash_f2m(SYSTEM_SPI_0_IO_CTRL, 0u, flash_offset + offset,
                     (uint32_t)(uintptr_t)chunk, count);
        crc = crc32_update(crc, chunk, count);

    }
    return (crc ^ 0xffffffffu) == style_crc(style) && cnn_in_validate_affine(style);
}

/* 各套原扫描包和 IN 数据原样存入各自 128KiB DDR 段，不改变 bin 排布。 */
static uint32_t preload_style(uint32_t style)
{
    uint32_t error;
    reg_write(REG_DDR_BANK, style);
    reg_write(REG_TOTAL_BYTES, CACHE_BYTES);
    reg_write(REG_EXPECTED_CRC, style_crc(style));
    reg_write(REG_CONTROL, CTRL_BEGIN);
    error = wait_status(ST_TX_READY);
    if (error) return error;
    cnn_bytes_sent = 0u;
    for (uint32_t region = 0; region < 2u; region++) {
        uint32_t bytes = region ? AFFINE_BYTES : WEIGHT_BYTES;
        uint32_t flash = region ? cnn_flash_offset + style_affine_offset[style] : style_offset(style);
        for (uint32_t offset = 0; offset < bytes; offset += CHUNK_BYTES) {
            uint32_t count = bytes - offset;
            if (count > CHUNK_BYTES) count = CHUNK_BYTES;
            spiFlash_f2m(SYSTEM_SPI_0_IO_CTRL, 0u, flash + offset, (uint32_t)(uintptr_t)chunk, count);
            for (uint32_t i = 0; i < count; i += 4u) {
                uint32_t word = (uint32_t)chunk[i] | ((uint32_t)chunk[i+1] << 8)
                              | ((uint32_t)chunk[i+2] << 16) | ((uint32_t)chunk[i+3] << 24);
                error = wait_status(ST_TX_READY);
                if (error) return error;
                reg_write(REG_DATA32, word);
                cnn_bytes_sent += 4u;
            }
        }
    }
    error = wait_status(ST_WRITE_DONE);
    if (error) return error;
    if (reg_read(REG_RECEIVED_BYTES) != CACHE_BYTES) return 4u;
    reg_write(REG_CONTROL, CTRL_CACHE);
    cnn_cached_styles |= 1u << style;
    return 0u;
}

/* IN 的校验和后台更新共用原 256B 缓冲；预载前从 Flash 读取，之后只读 DDR。 */
static uint32_t cnn_read_affine(uint32_t style, uint32_t offset, uint32_t count)
{
    if (!(cnn_cached_styles & (1u << style))) {
        spiFlash_f2m(SYSTEM_SPI_0_IO_CTRL, 0u, cnn_flash_offset + style_affine_offset[style] + offset,
                     (uint32_t)(uintptr_t)chunk, count);
        return 1u;
    }
    if (reg_read(REG_DDR_BANK) != style) return 0u;
    for (uint32_t i = 0; i < count; i += 16u) {
        reg_write(REG_AFFINE_READ, offset + i);
        if (wait_status(ST_AFFINE_READY)) return 0u;
        for (uint32_t j = 0; j < 16u; j += 4u) {
            uint32_t word = reg_read(REG_AFFINE_DATA + j);
            chunk[i+j] = (uint8_t)word;
            chunk[i+j+1] = (uint8_t)(word >> 8);
            chunk[i+j+2] = (uint8_t)(word >> 16);
            chunk[i+j+3] = (uint8_t)(word >> 24);
        }
    }
    return 1u;
}

static uint32_t load_style(uint32_t style)
{
    uint32_t error;
    reg_write(REG_DDR_BANK, style);
    if (!cnn_in_validate_affine(style)) return 6u;
    reg_write(REG_EXPECTED_CRC, style_crc(style));
    reg_write(REG_CONTROL, CTRL_COMMIT);
    cnn_boot_stage = 7u;
    error = wait_status(ST_PARAMS_READY);
    if (error) return error;
    cnn_boot_stage = 8u;
    cnn_active_style = style;
    cnn_in_reset();
    cnn_in_affine_checked = 1u;
    return 0u;
}

// 按键只提交风格请求；沿用排空、DDR选区、加载与IN重新启动的顺序。
static void switch_style(uint32_t target)
{
    if (cnn_runtime_fault || target >= STYLE_COUNT) return;
    if (target == cnn_active_style) {
        cnn_switch_error = 0u;
        return;
    }
    cnn_control_busy = 1u;
    if (!(cnn_cached_styles & (1u << target))) {
        cnn_switch_error = 6u;
    } else {
        cnn_switch_error = 0u;
        reg_write(REG_CONTROL, CTRL_QUIESCE);
        uint32_t error = wait_status(ST_RELOAD_READY);
        if (!error) error = load_style(target);
        // IN校验未通过时，仍按原协议恢复上一套风格。
        if (error == 6u && !(reg_read(REG_STATUS) & ST_ERROR)) {
            error = load_style(cnn_active_style);
            if (!error) cnn_switch_error = 6u;
        }
        if (error) {
            cnn_switch_error = error;
            cnn_runtime_fault = 1u;
        } else if (!cnn_switch_error) {
            cnn_switch_count++;
        }
    }
    cnn_control_busy = 0u;
}

int main(void)
{
    uint32_t request_seen = 0u;
    // CPU reset does not reload BRAM's writable .data from the bitstream.
    // Restore these startup values explicitly; start.S clears all .bss.
    cnn_flash_offset = CNN_FLASH_OFFSET;
    cnn_in_parallel = 1u;
    cnn_control_busy = 1u;
    bsp_init();
    cnn_boot_stage = 0x10u;
    uint32_t camera_result=camera_init();
    if(camera_result) stop_with_error(camera_result);
    /* Camera startup also runs in a CNN-bypass build; do not wait for weights. */
    if(!(reg_read(CAMERA_CONTROL_REG)&CAMERA_CNN_ENABLED))
        for (;;) { }
    cnn_boot_stage = 1u;
    if (cnn_flash_offset > FLASH_BYTES - 0x10000u - WEIGHT_BYTES)
        stop_with_error(1u);
    cnn_boot_stage = 2u;
    uint32_t error = wait_status(ST_CALIB_DONE);
    if (error) stop_with_error(error);
    spiFlash_init(SYSTEM_SPI_0_IO_CTRL, 0u);
    spiFlash_wake(SYSTEM_SPI_0_IO_CTRL, 0u);
    bsp_uDelay(50u);
    for (uint32_t style = 0; style < STYLE_COUNT; style++) {
        if (!validate_flash(style)) {
            if (style == 0u) stop_with_error(5u);
            continue;
        }
        error = preload_style(style);
        if (error) stop_with_error(error);
    }
    error = load_style(0u);
    if (error) stop_with_error(error);

    request_seen = reg_read(REG_STYLE_REQUEST) & 1u;
    cnn_control_busy = 0u;
    for (;;) {
        cnn_in_service();
        uint32_t request = reg_read(REG_STYLE_REQUEST) & 1u;
        if (request != request_seen) {
            request_seen = request;
            switch_style(next_style());
            // 切换期间的重复按键不排队，避免连续重载中断视频恢复。
            request_seen = reg_read(REG_STYLE_REQUEST) & 1u;
        }
    }
}
