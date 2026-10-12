# Портирование ядра

## Вариант A (рекомендуемый старт): msm-4.9 vendor + наш config-фрагмент
Pixel 3 официально стоит на 4.9; все blob-HAL совместимы. Минус: нет io_uring
(добавлен backport-патчем в patches/kernel, см. реестр релизов) и старый DRM.

```bash
scripts/build-boot.sh --legacy-4.9
```

## Вариант B: GKI 6.6 + DTBO-overlay
Нужен для BTI/PAC и современных devfreq-губернаторов. Работоспособность A630
через drm-msm на 6.6 проверена upstream (turnip gen7). Проблема: vendor HAL
Pixel 3 expects 4.9 ion/smem API — переходить только после porting layer.

## Чек-лист проверки ядра перед сборкой образа
- [ ] `CONFIG_MSM_KGSL=y` или `CONFIG_DRM_MSM=y` (по выбранному варианту)
- [ ] `CONFIG_EROFS_FS` + `LZ4` (rootfs)
- [ ] `CONFIG_ZRAM` (swap)
- [ ] `CONFIG_IO_URING=y` (FEX/Steam)
- [ ] `CONFIG_F2FS_FS=y` (home)
- [ ] devfreq governors: simple_ondemand, userspace
- [ ] DT alias gpu0 (udev rule)
