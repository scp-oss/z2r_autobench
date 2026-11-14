# gvfix — wssize_ramp для googlevideo + фикс DNS-коллектора

Ставит поверх существующих zator и zapret2 экспериментальную защиту видеопотока YouTube
из ветки `googlevideo-fix` zator (upstream [AloofLibra/zator](https://github.com/AloofLibra/zator),
тег `googlevideo-fix-beta.15`) и накладывает наш фикс DNS-коллектора.

## Зачем

ТСПУ режут видеопоток с иностранных кэшей Google (например, `rr*---sn-aj5go5-*.googlevideo.com`,
74.125.111.x) по IP: TCP открывается, данные после ClientHello не приходят. Кэш провайдера
(у Дом.ру `sn-xguxaxjvh`, 109.194.137.x) при этом работает. Симптом на клиенте: «каждое второе
видео не грузится». `wssize_ramp` обходит это для IP из набора ядра `z2r_googlevideo4`.
Набор пополняется DNS-коллектором (`googlevideo-dns-listener.sh` + сниффер).

## Фикс коллектора (`patch_googlevideo_ips.py`)

В upstream `lib/googlevideo_ips.sh` → `googlevideo_observe_local`:

1. При `already_reported` / `already_queued` (IP уже был в телеметрии) функция выходила
   **до** `nft add element`. После перезапуска zapret2 или истечения записи такие IP в набор
   больше не возвращались.
2. `config_get_var` не определена в процессе listener'а, поэтому `FWTYPE` пустой и вставка
   в набор не происходила **никогда** (Linux без OpenWrt).

Фикс выносит вставку в `googlevideo_kernel_add`, вызывает её сразу после записи наблюдения,
читает `FWTYPE` из конфига напрямую и ставит минимальный срок записи 1 ч
(`Z2R_GV_MIN_KERNEL_TTL`, по умолчанию 3600 с), потому что TTL в DNS — минуты.
Патч идемпотентный и проверяет, что структура upstream-файла та, которую он ожидает.

## Использование

```sh
sudo /opt/z2r_autobench/gvfix/install_gvfix.sh            # установить / обновить
sudo /opt/z2r_autobench/gvfix/install_gvfix.sh --status   # что стоит и работает ли
sudo /opt/z2r_autobench/gvfix/install_gvfix.sh --restore  # откат к последнему бэкапу
GVFIX_REF=googlevideo-fix-beta.16 sudo .../install_gvfix.sh  # другой тег upstream
```

Требования: zapret2 ≥ 1.0.7 (`nfqws2 --filter-mark`), конфиг zator с `#Z2R_AUTO_STANDARD_BEGIN`
и `fake-adapt.lua`, доступ к GitHub. Перед изменениями пишется бэкап в
`/opt/z2r_autobench/backups/gvfix/`; если zapret2 после перезапуска не поднялся, установщик
откатывается сам.

Важно: обновление zator через его меню перезапишет файлы. После обновления запусти установщик ещё раз.

## Файлы

| Файл | Что делает |
|---|---|
| `install_gvfix.sh` | скачивает файлы тега и бинарник сниффера под архитектуру, патчит, ставит, перезапускает, проверяет |
| `patch_googlevideo_ips.py` | фикс коллектора (см. выше) |
| `apply_ramp_config.py` | добавляет блоки `wssize_ramp` в `/opt/zapret2/config` (идемпотентно) |
