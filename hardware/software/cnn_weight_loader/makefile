PROJ_NAME=cnn_weight_loader
STANDALONE = ../../../software/cnn_boot_soc/software/standalone
BSP ?= efinix/EfxSapphireSoc
DEBUG ?= no

SRCS = $(wildcard src/*.c) \
       $(wildcard src/*.cpp) \
       $(wildcard src/*.S) \
       ${STANDALONE}/common/start.S

include ${STANDALONE}/common/bsp.mk

# Match the generated Lite core; do not emit M, A, C, F or D instructions.
RV_M = no
RV_A = no
RV_C = no
RV_F = no
RV_D = no
include ${STANDALONE}/common/riscv64-unknown-elf.mk

CFLAGS += -Isrc -flto -msave-restore
LDFLAGS += -flto
include ${STANDALONE}/common/standalone.mk
LDSCRIPT = ${BSP_PATH}/linker/default.ld
