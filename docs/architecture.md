# Архитектура PixelOS-Deck

## Слои загрузки

1. **Bootloader** (unlocked): грузит `boot.img` (GKI Image.gz + minikinit ramdisk).
2. **minikinit** (`initramfs/init`): монтирует erofs rootfs по `deck.root=` из cmdline,
   делает A/B fallback (`_a`→`_b`), биндит `/dev /proc /sys`, `switch_root` → systemd.
3. **systemd**: `deck.slice` + `steamdeck-session.service` запускают
   `deck-gamescope-session` → gamescope(DRM/GBM) → Steam Big Picture.
4. **vendor-раздел** остаётся андроидным: HAL графики (gralloc), прошивки ADSP/GPU
   подхватываются через `/vendor/firmware_mnt` и `/dev/kgsl-3d0`.

## Почему не Android+APK (путь DroidDeck)

DroidDeck работает *внутри* Android-песочницы: seccomp-фильтры приложения запрещают
io_uring и часть clone3, нет доступа к cpufreq/devfreq sysfs, desktop композится
программно. Нативный rootfs снимает все четыре ограничения одновременно; APK-путь
остаётся как запасной вариант (см. docs/status.md).

## Карта разделов

| Раздел | Файловая система | Назначение |
|---|---|---|
| boot_a/b | img header v3 | GKI Image.gz + initramfs |
| system_a/b → steamdeck | erofs lz4hc ro | targetfs (immutable, A/B) |
| vendor | ext4 ro | HAL/blob из factory |
| userdata/home | f2fs rw | игры, ~/.steam, state |
| persistent/state | ext4 rw | слот-независимые флаги, recovery |

## Потоки данных GPU

```
Steam UI (CEF/V8) ─┐
Games (native ARM64)─┼─► Turnip (Vulkan) ─► KGSL ─► A630 ─► DSI panel
DXVK/D3D9/11 ───────┘                         ▲
FEX x86→arm64 ─► wine-wow64 ─► DXVK ─────────┘
```
Zero-copy: gamescope использует GBM BO напрямую; dmabuf-цепочка не рвётся на CPU-copy
(в APK-пути разрыв был обязателен из-за AIDL composer).

## Ограничения платформы
- 2 GiB RAM: MemoryMax на slice, zram 2 GiB lz4, приоритет swap на zram.
- Нет adaptive refresh: фиксированные 60 Hz, vsync в gamescope обязателен.
- KGSL закрытый: thermal engine Android отсутствует → свой thermal-guard (см. overlay TODO).
