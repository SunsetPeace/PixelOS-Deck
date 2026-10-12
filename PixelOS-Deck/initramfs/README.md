# initramfs/minikinit

`init` — скрипт initrd (busybox ash). При сборке (`scripts/build-boot.sh`) рядом
должен лежать **статический busybox** в `initramfs/bin/busybox` и симлинк
`initramfs/bin/sh`. Скачайте: https://busybox.net/downloads/binaries/ (например
`busybox-armv8l_1.36.1-musl`, переименуйте в `bin/busybox`).

Скрипт монтирует erofs targetfs по `PARTNAME:`/`UUID:` из `deck.root=...` в
cmdline ядра, делает A/B-fallback (slot `_a` -> `_b`), r-bind'ит `/dev /proc /sys`
и передаёт управление systemd через `switch_root`.
