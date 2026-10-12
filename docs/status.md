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
| Thermal guard | ⚪ TODO | |

Легенда: ✅ готово · 🟡 частично · 🔴 заблокировано внешними артефактами · ⚪ план
