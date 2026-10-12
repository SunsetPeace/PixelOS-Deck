# Известные проблемы

1. **Turnip + DXVK 3**: `storageBuffer8BitAccess` отсутствует на gen7 (Adreno 6xx) —
   часть DX12-игр падает. Обходной путь в DroidDeck: DXVK 2. Тот же профиль у нас
   (`arm-optimizations/dxvk-a630.conf`). Статус: отслеживается upstream Mesa MR!
2. **2 GiB RAM**: крупные AAA-игры (>4 GiB textures) не помещаются даже с zram —
   ограничение железа, не софта.
3. **Тепловой троттлинг SD845**: без Android thermal-engine нужен пользовательский
   thermal-guard (TODO в overlay/usr/local/bin/deck-thermal-guard).
4. **Прошивки модема/Wi-Fi** лежат в vendor; при wipe vendor сеть не поднимется —
   flash.sh никогда не форматирует vendor.
5. **Factory images** Google отдаёт только по согласию — автоматическая загрузка
   невозможна, prepare-device.sh принимает локальный архив.
