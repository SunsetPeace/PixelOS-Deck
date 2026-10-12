# Статус портирования

| Компонент | Готовность | Примечание |
|---|---|---|
| Каркас сборки (scripts/configs) | ✅ готов | verify.py --offline проходит |
| initramfs/minikinit | ✅ готов | требует статический busybox при сборке |
| Конфиг устройства (blueline) | ✅ готов | размеры разделов проверить dump-partitions |
| Mesa/Turnip recipe | 🟡 собран конфиг, нужна проверка on-device | ICD json уложен |
| gamescope-session | 🟡 рецепт есть, бинарь собирается в CI | |
| FEX профиль a630 | 🟡 конфиг готов | SVE выключен осознанно |
| Steam/Proton укладка | 🔴 нужны staged-артефакты Valve (PROTON_STAGED) | |
| Пропшика на устройство | 🔴 blocked: unlocked bootloader + factory archive | |
| Thermal guard | 🟡 готов, нужна on-device калибровка | демон + 4 пресета (balanced/performance/powersave/quiet), unit, интеграция в rootfs; тесты bash/dash 39/39; после 15 мин нагрузки сверить `deck-thermal-guard show` с реальными зонами blueline |

Легенда: ✅ готово · 🟡 частично · 🔴 заблокировано внешними артефактами · ⚪ план
