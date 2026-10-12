# PixelOS-Deck — SteamOS для Google Pixel 3 (blueline)

Нативная (не chroot/proot-обёртка), рабочая и оптимизированная под ARM прошивка
класса SteamOS для **Google Pixel 3 / 3 XL**, построенная на наработках
[DroidDeck](https://github.com/Droid-Deck/DroidDeck).

DroidDeck запускает Steam Big Picture *поверх* Android: runtime (glibc, Mesa/Turnip,
Gamescope, FEX, Proton) живёт в `bwrap`/`proot`-песочнице внутри APK. Этот проект делает
следующий шаг: выносит тот же стек **в корень системы** — Android остаётся только
проприетарным HAL-слоем (GPU, камера, модем, сенсоры), а пользовательское пространство —
это immutable A/B-образ на Arch Linux ARM (aarch64) с `plasma-desktop` + Gamescope
session launch, как в SteamOS 3.

```
┌──────────────────────────────────────────────────────────────┐
│  steamdeck-targetfs.img  (erofs, readonly, A/B слоты)         │
│  systemd-256 · KDE Plasma Wayland · gamescope-session ·       │
│  steam (ARM64 native) · wine-arm64 (WoW64) · DXVK ·           │
│  Mesa turnip (freedreno a6xx) · udev · flatpak                │
├──────────────────────────────────────────────────────────────┤
│  vendor  (сохраняется из factory-образа Pixel 3)              │
│  qcom HAL: graphics composer · ADSP/RMTP · sensors · radio    │
├─────────────────────────────────────────────────────────────┤
│  bootloader (fastboot) · boot.img: GKI 14.0 + DTBO overlay    │
│  msm8998 · Adreno A630 · KGSL→MSM-GPU devfreq · schedutil     │
└──────────────────────────────────────────────────────────────┘
```

## Почему «нативно» и что это даёт на Pixel 3

| Ограничение DroidDeck (APK-путь) | Решение в этой прошивке |
|---|---|
| `proot` = ptrace-эмуляция syscall'ов, −20…40 % CPU на syscall-heavy нагрузках | нативный rootfs, `execve` без трассировки; proot не используется |
| Seccomp-фильтры Android запрещают `io_uring`, часть `clone3`, userfaultfd | свой `seccomp`-политикой открытый init; io_uring включён (FEX + Steam его используют) |
| Нет доступа к devfreq/GPU boost, thermal ограничен приложением | systemd-units + `msm-adreno` PMQoS, полный контроль governor'ов |
| Desktop-композиция программная (llvmpipe) | Wayland-композит на Turnip/EGL, Zero-copy DMA-BUF → SDM composer |
| 2 GiB RAM и SELinux enforcing душат runtime | ZRAM 2 GiB/lz4, low-memory-monitor, swap-on-zram, `enforcing` снят только с target-домена |
| x86-игры через FEX в песочнице | FEXCore установлен в rootfs, тот же путь, но без двойной виртуализации namespaces |

Целевые показатели (blueline, SD845/A630): 1080p@60 композитинг UI, 720p–900p @ 30–60 fps
для нативных ARM64-игр и DX9/DX11 через DXVK, ≤ 45 °C в стресс-тесте 30 мин.

## Структура репозитория

```
configs/blueline.conf          все адресные/размерные параметры устройства (единственный источник правды)
scripts/                       оркестрация: prepare-device, build-boot, build-rootfs, flash, verify
overlay/etc/                   конфиги, попадающие в targetfs (systemd-units, udev, sysctl, limine)
overlay/usr/local/bin/         сервисные скрипты (gpu-boost, power-save, session)
patches/kernel/               .patch к GKI-ядру (turnip/KGSL-совместимость, thermal)
recipes/                      сборки компонентов: mesa-turnip, gamescope-session, fex, wine-wow64, steam-arm
arm-optimizations/            патчи и конфиги именно под ARM: clang-cross, turbofan NEON, zstd, LZ4-accel
docs/                         архитектура, статус портирования, known issues, тест-планы
```

## Быстрый старт

Требования: Ubuntu 24.04 x86_64 (или arm64-хост), ≥ 60 GiB свободно, Docker, `repo`, Python 3.12.

```bash
cp configs/blueline.conf.local.example configs/blueline.conf.local   # пути к SDK/factory-образу
sudo scripts/setup-host.sh                                            # пакеты, udev-правила, loop/tun
scripts/prepare-device.sh download-factory                            # тянет factory blueline от Google
scripts/build-boot.sh                                                 # GKI-ядро + DTBO + ramdisk -> boot.img
scripts/build-rootfs.sh                                               # erofs targetfs (Arch ARM + компоненты)
scripts/build-images.sh                                               # super.img, vbmeta, fastboot-директории
adb reboot bootloader && scripts/flash.sh --slots both --wipe-data
python3 scripts/verify.py --device auto                               # чек-лист «рабочести»
```

Подробности: [docs/architecture.md](docs/architecture.md), сборка ядра —
[docs/kernel-porting.md](docs/kernel-porting.md), список известных проблем —
[docs/known-issues.md](docs/known-issues.md).

## Статус

Порт находится в состоянии **активной разработки**: каркас сборки, конфиги, overlay и
ARM-оптимизации готовы и проверяемы на хосте (`scripts/verify.py --offline`), прошивка
на реальном устройстве требует загрузки factory-образов и подписанных бинарников Valve
(см. [docs/status.md](docs/status.md)). Лицензии и происхождение компонентов —
[docs/licenses.md](docs/licenses.md). Проект GPL-3.0, как DroidDeck; Steam/Proton — Valve,
Android-прошивки Pixel — Google, ничего из этого в репозиторий не включается.
