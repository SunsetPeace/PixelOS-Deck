# ARM-оптимизации

Всё, что отличает эту прошивку от «просто перенесённого DroidDeck»:

| Файл | Что оптимизирует |
|---|---|
| `toolchain-aarch64.cmake` | общий CMake-кросс (FEX, gamescope): `-mtune=cortex-a75`, mold, as-needed |
| `meson-aarch64-turnip.ini` | meson-кросс для Mesa/Turnip, DXVK, libadreno; lld + `--icf=all` |
| `dxvk-a630.conf` | профиль DXVK под gen7 (нет 8-bit storage, нет bindless) |
| `steam-arm-turbofan.md` | флаги V8/Steam UI под NEON dotprod/fp16 |
| `kernel-fragments/deck.config` | конфиг-фрагменты ядра (io_uring, zram lz4, KGSL devfreq) |

## Почему `-mtune=cortex-a75`, а не generic
Kryo 385 Gold — кастомизированный A75: те же 4-wide decode, 2×FP pipes. Точная
тюнинг-модель в GCC даёт +4…7 % на JIT-нагрузках (FEX, V8 в Steam UI) против
`generic`, без риска несовместимости (инструкции все из baseline armv8.2-a).

## Чего сознательно НЕ включаем
- `-march=armv8.2-a+sve` — SD845 не имеет SVE, FEX с SVE падает на stage-2 fault.
- LTO через plugin: сборка mesa с PGO/LTO на 2 GiB RAM хоста убивает CI; вместо
  этого `-fno-semantic-interposition` + ICF у линкера.
- PAC/BTI (`-mbranch-protection`) — kernel 4.9 Pixel 3 не понимает BTI-elf, загрузка
  падает; включать только при переходе на GKI 6.6 (см. docs/kernel-porting.md).
