# Матрикс. Инструкции и конфиги
[English ReadMe](https://github.com/kryptonmourog/matrix-instruction-and-configs/blob/master/README_EN.MD)

Репозиторий на базе которого всё делаем:
https://github.com/spantaleev/matrix-docker-ansible-deploy

## Сокращённый гайд

**Команда для запуска скрипта установки (скопировать и запустить НА СЕРВЕРЕ):**
```bash
curl -O https://raw.githubusercontent.com/kryptonmourog/matrix-instruction-and-configs/refs/tags/v1.1.3/scripts/matrix_up.sh && chmod +x matrix_up.sh && sudo ./matrix_up.sh
```

Скрипт сохраняет ответы и сгенерированные секреты в файл `.env` рядом с собой. Не удаляйте его: при повторном запуске из той же папки скрипт спрашивает только логин и пароль админа, а пароль базы и ключи не меняет. Если на сервере уже есть установка (в том числе сделанная прошлыми версиями скрипта), её домены и секреты переносятся в `.env` автоматически.

**Обновление уже установленного сервера** (в том числе поставленного прошлыми версиями скрипта):
```bash
curl -O https://raw.githubusercontent.com/kryptonmourog/matrix-instruction-and-configs/refs/tags/v1.1.3/scripts/matrix_up.sh && chmod +x matrix_up.sh && sudo ./matrix_up.sh --update
```
Сначала `--update` проверяет, не вышел ли более новый релиз скрипта той же мажорной версии (v1.x), и если вышел, скачивает его, проверяет и продолжает уже новой версией. На следующую мажорную версию (v2.0.0) скрипт сам не переходит, только предупреждает. Остаться на текущей версии: `sudo ./matrix_up.sh --update --no-self-update`.

Режим `--update` ничего не спрашивает и не пересоздаёт `vars.yml`, поэтому ручные правки в нём сохраняются. Он переводит плейбук на версию, проверенную в этом релизе (более новую не откатывает), обновляет роли и запускает установку. В `vars.yml` меняется только `matrix_playbook_migration_validated_version`, прошлый файл сохраняется рядом как `vars.yml.bak-ДАТА`.

Список версий и изменений: [Releases](https://github.com/kryptonmourog/matrix-instruction-and-configs/releases).

Видео-инструкция:
https://www.youtube.com/watch?v=GGaM5asQGxE


## Полный гайд
Моя инструкция:
https://docs.google.com/document/d/1Dox26X0Rt3AuAhWyyuIXTLwvM6RRhxVPvqRuELNR2ws

Видео-инструкция:
https://www.youtube.com/watch?v=l7BLIRAxqzs

## Где что искать
Конфиги:
- В этом репозитории, в папке `configs`

Скрипты:
- В этом репозитории, в папке `scripts`

## Лицензия
GNU GPL v3.0, см. [LICENSE](LICENSE). Часть JS-скриптов для Xray адаптирована из [3X-UI](https://github.com/MHSanaei/3x-ui) (GPL-3.0).
