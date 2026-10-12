# SPDX-License-Identifier: GPL-3.0-only
# Кросс-тулчейн aarch64 с тюнингом под Snapdragon 845 (Cortex-A75 производные).
set(CMAKE_SYSTEM_NAME Linux)
set(CMAKE_SYSTEM_PROCESSOR aarch64)
set(CMAKE_C_COMPILER   aarch64-linux-gnu-gcc)
set(CMAKE_CXX_COMPILER aarch64-linux-gnu-g++)
set(CMAKE_ASM_COMPILER aarch64-linux-gnu-gcc)
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)

# -mcpu=cortex-a75: есть в GCC>=10; для clang используйте cortex-a76 (a75 нет,
# а76 даёт идентичный pipeline на Kryo 385).
set(FREQ_FLAGS "-march=armv8.2-a+crypto+fp16+dotprod -mtune=cortex-a75")
set(CMAKE_C_FLAGS_INIT   "${FREQ_FLAGS} -O3 -fomit-frame-pointer -fno-semantic-interposition")
set(CMAKE_CXX_FLAGS_INIT "${FREQ_FLAGS} -O3 -fomit-frame-pointer -fno-semantic-interposition")
set(CMAKE_EXE_LINKER_FLAGS_INIT "-Wl,-O2 -Wl,--as-needed -Wl,--hash-style=gnu -fuse-ld=mold")
