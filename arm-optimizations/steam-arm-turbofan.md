# Steam UI (Chromium/V8) на aarch64

Steam Big Picture рисует UI через CEF. На 845 узкое место — не GPU, а main thread
в V8. Что делаем:

1. `--js-flags="--max-opt --cpu-prof"` убираем; вместо этого запускаем steam с
   `--disable-gpu-vsync --disable-composeapi` (compose API на turnip генерирует
   лишние vkQueueSubmit).
2. Собираем wrapper `deck-steam-launch` с `taskset -c 4-7` для steamwebhelper —
   big cores не дают UI-треду уплыть на Silver и деградировать частоту.
3. В `/etc/default/deck-session` ставим `STEAM_SKIP_PROTON_BOOTSTRAP=1`:
   нативный ARM64 Steam не тянет x86 client runtime (в APK-пути это ~1.1 ГБ
   трафика и лишние mount namespace).
