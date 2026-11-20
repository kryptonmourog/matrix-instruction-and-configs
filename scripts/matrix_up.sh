#!/bin/bash
# Установка и обслуживание Matrix (matrix-docker-ansible-deploy) и, по желанию, Xray-прокси
# и моста Telegram (telegram-bridge-advanced: на этом сервере или на отдельном).
#
# Первый запуск: скачать и выполнить sudo ./matrix_up.sh. Скрипт копирует себя в систему,
# дальше он доступен как команда matrix-up (или matrix_up) и открывает панель управления.
#
# Параметры хранятся в /etc/matrix_up/matrix.env. Недостающие значения спрашиваются и сохраняются
# туда же. Секреты генерируются один раз, поэтому повторная установка не меняет пароль БД и ключи.
# Если на сервере уже есть установка (в том числе сделанная версией v1.0.0), значения и секреты
# берутся из её vars.yml. Шаблон configs/vars.yml скачивается из репозитория и заполняется параметрами.
#
# Запуск: sudo matrix-up [--install | --update] [--plain]   (подробно: matrix-up --help)

set -euo pipefail

RELEASE_TAG="v1.3.0"
PROJECT_URL="https://github.com/kryptonmourog/matrix-instruction-and-configs"
RAW_ROOT="https://raw.githubusercontent.com/kryptonmourog/matrix-instruction-and-configs/refs/tags"
RAW_BASE="${RAW_ROOT}/${RELEASE_TAG}"
PLAYBOOK_REPO="https://github.com/spantaleev/matrix-docker-ansible-deploy.git"
# У плейбука нет git-тегов, поэтому он фиксируется по коммиту, на котором проверен этот релиз.
# PLAYBOOK_VERSION должна совпадать с matrix_playbook_migration_validated_version в configs/vars.yml.
PLAYBOOK_COMMIT="53bf00e192e971b72bb62c0d28f0d5599eb97cae"
PLAYBOOK_VERSION="v2026.05.18.0"
PROXY_PORT=10809
DOCKER_BRIDGE_IP="172.17.0.1"
# Мост Telegram: образ форка (на этом сервере) и роль для отдельного сервера, проверенные в этом релизе
BRIDGE_IMAGE="ghcr.io/kryptonmourog/telegram-bridge-advanced:v0.2611.0-adv"
BRIDGE_ROLE_REPO="https://github.com/kryptonmourog/telegram-bridge-advanced-ansible.git"
BRIDGE_ROLE_TAG="v0.2611.0-adv.2"
BRIDGE_ROLE_DIR="telegram-advanced"
BRIDGE_SSH_KEY="/root/.ssh/matrix_up_telegram"
BRIDGE_WSPROXY_DIR="/opt/matrix-telegram-wsproxy"
BRIDGE_REGISTRATION="$BRIDGE_WSPROXY_DIR/registration.yaml"
BRIDGE_REMOTE_DIR="/opt/mautrix-telegram"
BRIDGE_BLOCK_BEGIN="# >>> matrix-up: мост Telegram"
BRIDGE_BLOCK_END="# <<< matrix-up: мост Telegram"

RED='\e[31m'
GREEN='\e[32m'
YELLOW='\e[33m'
GRAY='\e[90m'
NC='\e[0m'

# Исходные stdout и stderr. В режиме gum вывод шагов уходит в журнал, а сообщения - сюда.
exec 8>&1 9>&2

# ---------- интерфейс: gum в терминале, обычный текст без него ----------

UI=plain          # gum | plain
UI_REQUEST=auto   # plain - если передан --plain
GUM=""
GUM_VERSION="2.0.2"
GUM_SHA256_X86_64="d842e06d93dbed90af48cb8dd10698db6f22e331fc40346bb37bbc753109edc2"
GUM_SHA256_ARM64="8ebf8b54ec1e8c81f2bb58b59ff9b70998186a4d11375f0cf357b80e0ccfa1d5"
# Системная установка скрипта: команды matrix-up и matrix_up ведут на копию в INSTALL_DIR
INSTALL_DIR="/usr/local/lib/matrix_up"
INSTALLED_SCRIPT="$INSTALL_DIR/matrix_up.sh"
COMMAND_NAMES=(matrix-up matrix_up)
BIN_DIR="/usr/local/bin"
# Параметры и секреты установки (раньше лежали в .env рядом со скриптом)
CONFIG_DIR="/etc/matrix_up"
# Не в PATH, чтобы не мешать gum, который мог быть установлен отдельно
GUM_DIR="$INSTALL_DIR/gum-${GUM_VERSION}"
LOG_FILE="/var/log/matrix_up.log"
WORK_DIR=""
STEP_NO=0
STEP_TOTAL=0
STEP_TITLE=""
STEP_HINT=""
STEP_NOTES=()
STEP_WARNINGS=()
SPIN_PID=""
DIE_MSG=""
INTERRUPT_MSG=""
BACK=2  # код возврата "вернуться к предыдущему вопросу"
SKIP=3  # код возврата "вопрос сейчас не нужен"

die() {
    # До установки ловушки EXIT и в подоболочке $(...) сообщение печатается сразу
    if [ -z "$WORK_DIR" ] || [ "$BASH_SUBSHELL" -gt 0 ]; then
        printf "${RED}Ошибка: %s${NC}\n" "$*" >&9
        exit 1
    fi
    DIE_MSG="$*"
    exit 1
}

# Предупреждение. Во время шага в режиме gum показывается под строкой шага.
warn() {
    if [ "$UI" = gum ] && [ -n "$STEP_TITLE" ]; then
        printf 'Внимание: %s\n' "$*"
        STEP_WARNINGS+=("$*")
    else
        printf "${YELLOW}Внимание: %s${NC}\n" "$*" >&9
    fi
}

# Пояснение для пользователя. Во время шага в режиме gum показывается под строкой шага.
note() {
    if [ "$UI" != gum ]; then
        printf '%s\n' "$*"
    elif [ -n "$STEP_TITLE" ]; then
        printf '%s\n' "$*"
        STEP_NOTES+=("$*")
    else
        printf "  ${GRAY}%s${NC}\n" "$*" >&9
    fi
}

stop_spinner() {
    [ -n "$SPIN_PID" ] || return 0
    local i sig
    # Спиннер ждёт команду-заглушку; завершаем её, и gum сам убирает строку.
    # Если gum не успел её запустить, он не завершится сам, а SIGTERM может игнорировать.
    for sig in "" TERM KILL; do
        [ -z "$sig" ] || kill -s "$sig" "$SPIN_PID" 2> /dev/null || true
        for i in 1 2 3 4 5 6 7 8 9 10; do
            pkill -P "$SPIN_PID" 2> /dev/null || true
            kill -0 "$SPIN_PID" 2> /dev/null || break 2
            sleep 0.1
        done
    done
    wait "$SPIN_PID" 2> /dev/null || true
    SPIN_PID=""
    # Курсор и режим вставки, если gum был остановлен принудительно
    printf '\r\033[K\033[?25h\033[?2004l' >&9
}

on_exit() {
    local rc=$?
    stop_spinner
    if [ "$rc" -ne 0 ]; then
        if [ "$UI" = gum ] && [ -n "$STEP_TITLE" ] && [ "$rc" -eq 130 ]; then
            printf "  ${YELLOW}■${NC} %s\n" "$STEP_TITLE" >&9
        elif [ "$UI" = gum ] && [ -n "$STEP_TITLE" ]; then
            printf "  ${RED}✗${NC} %s\n\n" "$STEP_TITLE" >&9
            printf "${GRAY}Последние строки журнала %s:${NC}\n" "$LOG_FILE" >&9
            tail -n 25 "$LOG_FILE" 2> /dev/null | sed 's/^/  │ /' >&9 || true
            printf '\n' >&9
        fi
        if [ -n "$INTERRUPT_MSG" ]; then
            printf '%b%s%b\n' "$YELLOW" "$INTERRUPT_MSG" "$NC" >&9
        elif [ -n "$DIE_MSG" ]; then
            printf "${RED}Ошибка: %s${NC}\n" "$DIE_MSG" >&9
        elif [ -n "$STEP_TITLE" ]; then
            printf "${RED}Ошибка: шаг «%s» завершился с ошибкой (код %s)${NC}\n" "$STEP_TITLE" "$rc" >&9
        fi
        if [ "$UI" = gum ] && [ -n "$STEP_TITLE" ]; then
            printf 'Полный журнал: %s\n' "$LOG_FILE" >&9
        fi
    fi
    [ -z "$WORK_DIR" ] || rm -rf "$WORK_DIR"
}

# Ctrl+C в вопросах: спокойное сообщение вместо ошибки (работает и внутри $(...))
cancel_input() {
    if [ -n "${ENV_FILE:-}" ] && [ -s "$ENV_FILE" ]; then
        printf "\n${YELLOW}Отменено. Введённые ответы сохранены в %s, при следующем запуске их можно принять или исправить.${NC}\n" "$ENV_FILE" >&9
    else
        printf '\n%bОтменено.%b\n' "$YELLOW" "$NC" >&9
    fi
    exit 130
}

# gum после Esc печатает "not submitted" / "nothing selected" - стираем эту строку
clear_gum_line() {
    printf '\033[1A\r\033[2K' >&9
}

# Ctrl+C или закрытие терминала. Без этого Ctrl+C во время шага прерывал только текущую
# команду, а повторы run_with_retry молча запускали её снова.
on_interrupt() {
    trap - INT TERM HUP
    if [ -n "$STEP_TITLE" ]; then
        INTERRUPT_MSG="Прервано на шаге «$STEP_TITLE». Запустите скрипт снова, чтобы продолжить: введённые параметры сохранены."
        exit 130
    fi
    cancel_input
}

# Очистка экрана (для панели и переходов из неё)
ui_clear() {
    [ -t 1 ] || return 0
    printf '\033[H\033[2J' >&9
}

fmt_duration() {
    local s="$1"
    if [ "$s" -lt 60 ]; then
        printf '%d с' "$s"
    else
        printf '%d мин %d с' $((s / 60)) $((s % 60))
    fi
}

# gum включается, только если ввод и вывод - терминал. Бинарник фиксированной версии
# скачивается один раз, сверяется по SHA-256 и хранится в $GUM_DIR для следующих запусков.
ui_init() {
    [ "$UI_REQUEST" != plain ] || return 0
    [ -t 0 ] && [ -t 1 ] && [ -t 2 ] || return 0
    [ "${TERM:-dumb}" != dumb ] || return 0
    local arch sum
    case "$(uname -m)" in
        x86_64) arch=x86_64 sum="$GUM_SHA256_X86_64" ;;
        aarch64 | arm64) arch=arm64 sum="$GUM_SHA256_ARM64" ;;
        *) return 0 ;;
    esac
    local name="gum_${GUM_VERSION}_Linux_${arch}"
    # Журнал нужен, чтобы убрать вывод шагов с экрана. Без журнала остаёмся в текстовом режиме.
    if ! (umask 077 && touch "$LOG_FILE") 2> /dev/null; then
        LOG_FILE="$SCRIPT_DIR/matrix_up.log"
        if ! (umask 077 && touch "$LOG_FILE") 2> /dev/null; then
            warn "не удалось создать журнал установки, продолжаем в текстовом режиме"
            return 0
        fi
    fi
    chmod 600 "$LOG_FILE" 2> /dev/null || true
    if "$GUM_DIR/gum" --version 2> /dev/null | grep -q "v$GUM_VERSION"; then
        GUM="$GUM_DIR/gum"
    else
        printf 'Загружаем интерфейс (gum %s)...' "$GUM_VERSION" >&9
        if curl -fsSL --max-time 60 "https://github.com/charmbracelet/gum/releases/download/v${GUM_VERSION}/${name}.tar.gz" \
            -o "$WORK_DIR/gum.tar.gz" 2> /dev/null \
            && echo "$sum  $WORK_DIR/gum.tar.gz" | sha256sum -c --status \
            && tar --no-same-owner -xzf "$WORK_DIR/gum.tar.gz" -C "$WORK_DIR" "$name/gum" 2> /dev/null \
            && "$WORK_DIR/$name/gum" --version > /dev/null 2>&1; then
            # Сохраняем для следующих запусков; не вышло - работаем из временной папки
            if install -D -m 755 "$WORK_DIR/$name/gum" "$GUM_DIR/gum" 2> /dev/null; then
                GUM="$GUM_DIR/gum"
            else
                GUM="$WORK_DIR/$name/gum"
            fi
        fi
        printf '\r\033[K' >&9
    fi
    if [ -z "$GUM" ]; then
        warn "не удалось загрузить gum, продолжаем в текстовом режиме"
        return 0
    fi
    UI=gum
    printf '\n===== %s matrix_up.sh %s =====\n' "$(date '+%F %T')" "$RELEASE_TAG" >> "$LOG_FILE"
}

ui_banner() {
    if [ "$UI" = gum ]; then
        # Отступы - обычными переводами строки: --margin у gum рисует строки из пробелов
        printf '\n' >&9
        "$GUM" style --border rounded --border-foreground 212 --padding "0 2" \
            -- "$("$GUM" style --bold --foreground 212 -- "$1")" "$("$GUM" style --faint -- "$2")" >&9
        printf '\n' >&9
    else
        printf '\n=== %s ===\n%s\n' "$1" "$2"
    fi
}

ui_section() {
    if [ "$UI" = gum ]; then
        printf '\n' >&9
        "$GUM" style --bold --foreground 212 -- "$1" >&9
    else
        printf '\n=== %s ===\n' "$1"
    fi
}

# ui_table подпись значение [подпись значение ...] - две колонки в рамке
ui_table() {
    local labels=() values=() i
    while [ "$#" -ge 2 ]; do
        labels+=("$1")
        values+=("$2")
        shift 2
    done
    if [ "$UI" = gum ]; then
        local c1 c2
        c1="$("$GUM" style --foreground 245 -- "${labels[@]}")"
        c2="$("$GUM" style --margin "0 0 0 2" -- "${values[@]}")"
        "$GUM" join --horizontal "$c1" "$c2" | "$GUM" style --border rounded --border-foreground 240 --padding "0 1" >&9
    else
        for i in "${!labels[@]}"; do
            printf '  %s: %s\n' "${labels[$i]}" "${values[$i]}"
        done
    fi
}

# Строка "принято" после ответа (в текстовом режиме ответ и так виден)
ui_answer() {
    [ "$UI" = gum ] || return 0
    printf "  ${GREEN}✓${NC} ${GRAY}%s:${NC} %s\n" "$1" "$2" >&9
}

ui_invalid() {
    if [ "$UI" = gum ]; then
        printf "  ${RED}✗ %s${NC}\n" "$1" >&9
    else
        printf '  %s\n' "$1" >&9
    fi
}

# prompt_value "вопрос" "по умолчанию" [secret] - печатает ответ.
# Вызывается только как $(prompt_value ...): код 2 - "назад", остальные ненулевые - ошибка (уже выведена).
prompt_value() {
    local prompt="$1" default="${2:-}" secret="${3:-}" value="" rc=0
    if [ "$UI" = gum ]; then
        local args=(input --header "$prompt" --prompt "› " --width 0 --char-limit 0)
        if [ -n "$secret" ]; then
            args+=(--password --placeholder "Enter — сгенерировать")
        else
            args+=(--value "$default")
        fi
        value="$("$GUM" "${args[@]}")" || rc=$?
        case "$rc" in
            0) ;;
            1)
                clear_gum_line
                exit "$BACK"
                ;; # Esc
            *) cancel_input ;;
        esac
    else
        local shown="$prompt"
        [ -z "$default" ] || shown+=" [$default]"
        if [ -n "$secret" ]; then
            read -rs -p "$shown: " value || die "ввод закончился, а ответы ещё нужны"
            echo >&9
        else
            read -r -p "$shown: " value || die "ввод закончился, а ответы ещё нужны"
        fi
        [ "$value" != "<" ] || exit "$BACK"
        [ -n "$value" ] || value="$default"
    fi
    printf '%s' "$value"
}

# ui_yes_no "вопрос" yes|no -> 0 да, 1 нет, 2 назад
ui_yes_no() {
    local question="$1" def="$2" answer rc=0
    if [ "$UI" = gum ]; then
        local yes="Да" no="Нет" back="← Назад" selected
        if [ "$def" = yes ]; then selected="$yes"; else selected="$no"; fi
        answer="$("$GUM" choose --header "$question" --selected "$selected" -- "$yes" "$no" "$back")" || rc=$?
        case "$rc" in
            0) ;;
            1)
                clear_gum_line
                return "$BACK"
                ;;
            *) cancel_input ;;
        esac
        [ "$answer" != "$back" ] || return "$BACK"
        if [ "$answer" = "$yes" ]; then return 0; fi
        return 1
    fi
    local hint="y/N"
    [ "$def" != yes ] || hint="Y/n"
    read -r -p "$question [$hint, < — назад]: " answer || die "ввод закончился, а ответы ещё нужны"
    [ "$answer" != "<" ] || return "$BACK"
    if [ -z "$answer" ]; then
        [ "$def" = yes ] && return 0
        return 1
    fi
    if [[ "$answer" =~ ^[YyДд] ]]; then return 0; fi
    return 1
}

# run_step "Название" функция [аргументы]
# Функция выполняется в этом же процессе (её переменные, cd и export сохраняются).
# В режиме gum её вывод уходит в журнал, а на экране крутится спиннер.
run_step() {
    local title="$1"
    shift
    STEP_NO=$((STEP_NO + 1))
    STEP_TITLE="[$STEP_NO/$STEP_TOTAL] $title"
    STEP_NOTES=()
    STEP_WARNINGS=()
    if [ "$UI" != gum ]; then
        printf '\n=== %s ===\n' "$STEP_TITLE"
        "$@"
        STEP_TITLE=""
        return 0
    fi
    printf '\n===== %s =====\n' "$STEP_TITLE" >> "$LOG_FILE"
    local start="$SECONDS" line
    "$GUM" spin --spinner dot --title "$STEP_TITLE${STEP_HINT:+  ($STEP_HINT)}" -- tail --pid="$$" -f /dev/null < /dev/null >&9 2>&9 &
    SPIN_PID=$!
    "$@" >> "$LOG_FILE" 2>&1
    stop_spinner
    printf "  ${GREEN}✓${NC} %s ${GRAY}%s${NC}\n" "$STEP_TITLE" "$(fmt_duration $((SECONDS - start)))" >&9
    for line in "${STEP_NOTES[@]}"; do
        printf "      ${GRAY}%s${NC}\n" "$line" >&9
    done
    for line in "${STEP_WARNINGS[@]}"; do
        printf "      ${YELLOW}! %s${NC}\n" "$line" >&9
    done
    STEP_TITLE=""
}

usage() {
    cat <<EOF
Использование (после первого запуска скрипт доступен как команда matrix-up или matrix_up):
  sudo matrix-up                 панель управления, если Matrix уже установлен (в ней же установка и удаление
                                 моста Telegram); иначе установка
  sudo matrix-up --install       установка или переустановка: вопросы, параметры в $CONFIG_DIR/matrix.env,
                                 пересоздание vars.yml
  sudo matrix-up --update        обновление установленного сервера до версии плейбука из релиза ${RELEASE_TAG}:
                                 ничего не спрашивает, vars.yml не пересоздаёт.
                                 Сначала сам переходит на последний релиз скрипта ${RELEASE_TAG%%.*}.x, если он вышел
  --no-self-update               вместе с --update: не обновлять скрипт, остаться на ${RELEASE_TAG}
  --plain                        обычный текстовый вывод без интерфейса gum
EOF
}

MODE=auto
SELF_UPDATE=yes
for arg in "$@"; do
    case "$arg" in
        --install) MODE=install ;;
        --update) MODE=update ;;
        --no-self-update) SELF_UPDATE=no ;;
        --plain) UI_REQUEST=plain ;;
        -h | --help)
            usage
            exit 0
            ;;
        *)
            usage >&2
            die "неизвестный параметр: $arg"
            ;;
    esac
done
[ "$SELF_UPDATE" = yes ] || [ "$MODE" = update ] || die "--no-self-update используется только вместе с --update"

# Настоящий путь к скрипту (команда matrix-up - это ссылка на него)
SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"

if [ "$(id -u)" -ne 0 ]; then
    if [ -f "$SCRIPT_PATH" ] && command -v sudo > /dev/null 2>&1; then
        exec sudo bash "$SCRIPT_PATH" "$@"
    fi
    die "запустите скрипт через sudo: sudo $0 $*"
fi

TARGET_USER="${SUDO_USER:-root}"
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
[ -n "$TARGET_HOME" ] || die "не удалось определить домашний каталог пользователя $TARGET_USER"

ENV_FILE="$CONFIG_DIR/matrix.env"
OLD_ENV_FILE="$SCRIPT_DIR/.env"

# Рабочая папка для скачанных файлов. Удаляется при любом выходе.
WORK_DIR="$(mktemp -d)"
trap on_exit EXIT
trap on_interrupt INT TERM HUP

# run_with_retry "команда" [число попыток, по умолчанию 15]
run_with_retry() {
    local cmd="$1"
    local max_attempts="${2:-15}"
    local iterator=1

    while [ "$iterator" -le "$max_attempts" ]; do
        echo "Запуск: $cmd (Попытка $iterator из $max_attempts)"
        if eval "$cmd"; then
            echo "Команда '$cmd' выполнена успешно!"
            return 0
        fi
        if [ "$iterator" -lt "$max_attempts" ]; then
            echo "Ошибка при выполнении. Повтор через 5 секунд..."
            sleep 5
        fi
        iterator=$((iterator + 1))
    done

    echo "Ошибка: Команда '$cmd' не удалась после $max_attempts попыток."
    return 1
}

download() {
    curl -fsSL "$1" -o "$2" || die "не удалось скачать $1"
}

# wait_for_port хост порт секунд: ждёт, пока порт начнёт принимать соединения
wait_for_port() {
    local i
    for ((i = 0; i < $3; i++)); do
        if (exec 3<> "/dev/tcp/$1/$2") 2> /dev/null; then
            return 0
        fi
        sleep 1
    done
    return 1
}

# ---------- работа с .env (без source: файл читается как данные) ----------

env_get() {
    sed -n "s/^$1=\"\(.*\)\"\$/\1/p" "$ENV_FILE" | tail -n 1
}

env_set() {
    local key="$1" value="$2" tmp
    tmp="$(mktemp "$WORK_DIR/env.XXXXXX")"
    grep -v "^$key=" "$ENV_FILE" > "$tmp" || true
    printf '%s="%s"\n' "$key" "$value" >> "$tmp"
    cat "$tmp" > "$ENV_FILE"
    chmod 600 "$ENV_FILE"
}

# Секрет: генерируется один раз и сохраняется в .env
ensure_secret() {
    local var="$1" value
    value="$(env_get "$var")"
    if [ -z "$value" ]; then
        value="$(openssl rand -hex 32)"
        env_set "$var" "$value"
    fi
    printf -v "$var" '%s' "$value"
}

# ---------- проверки и нормализация ввода ----------

# Нижний регистр, без точки в конце; кириллический домен (пример.рф) переводится в punycode.
normalize_domain() {
    local d="${1,,}"
    d="${d%.}"
    if [[ "$d" =~ [^a-z0-9.-] ]] && command -v python3 > /dev/null 2>&1; then
        d="$(python3 -c 'import sys; print(sys.argv[1].encode("idna").decode())' "$d" 2> /dev/null)" || d=""
    fi
    printf '%s' "$d"
}

is_ipv4() {
    local IFS=. o x
    [[ "$1" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 1
    read -ra o <<< "$1"
    for x in "${o[@]}"; do
        [ "$((10#$x))" -le 255 ] || return 1
    done
}
# TLD: обычный (com, ru) или punycode (xn--p1ai для .рф)
is_domain()   { [[ "$1" =~ ^([a-z0-9]([a-z0-9-]*[a-z0-9])?\.)+([a-z]{2,}|xn--[a-z0-9-]+)$ ]]; }
is_email()    { [[ "$1" =~ ^[^@[:space:]\'\"]+@[^@[:space:]\'\"]+\.[^@[:space:]\'\"]+$ ]]; }
is_nick()     { [[ "$1" =~ ^[a-z0-9._=-]+$ ]]; }
is_vless()    { [[ "$1" =~ ^vless:// ]]; }
# MAS отклоняет простые пароли, поэтому требуем длину и разные типы символов.
# Это не гарантия: окончательное решение принимает MAS при регистрации.
is_password() {
    [ "${#1}" -ge 12 ] || return 1
    [[ "$1" =~ [a-z] ]] || return 1
    [[ "$1" =~ [A-Z] ]] || return 1
    [[ "$1" =~ [0-9] ]] || return 1
    [[ "$1" =~ [[:space:]] ]] && return 1
    return 0
}

# ---------- шаг 0: существующая установка ----------

# Плейбук от прошлых запусков: v1.0.0 под sudo клонировал в /root, v1.1.0 — в домашний каталог.
# Берём каталог, где уже есть конфиг, чтобы не завести вторую копию с другими секретами.
find_repo_dir() {
    local d
    for d in "$TARGET_HOME/matrix-docker-ansible-deploy" "/root/matrix-docker-ansible-deploy"; do
        if compgen -G "$d/inventory/host_vars/*/vars.yml" > /dev/null; then
            echo "$d"
            return
        fi
    done
    for d in "$TARGET_HOME/matrix-docker-ansible-deploy" "/root/matrix-docker-ansible-deploy"; do
        if [ -d "$d/.git" ]; then
            echo "$d"
            return
        fi
    done
    echo "$TARGET_HOME/matrix-docker-ansible-deploy"
}

# Переносит значения и секреты из vars.yml прошлой установки в .env (только отсутствующие в .env).
# Без этого повторный запуск сгенерировал бы новые пароль БД и ключи и сломал бы Postgres и MAS.
import_existing_vars() {
    local files=() existing key value
    if compgen -G "$REPO_DIR/inventory/host_vars/*/vars.yml" > /dev/null; then
        files=("$REPO_DIR"/inventory/host_vars/*/vars.yml)
    fi
    [ "${#files[@]}" -gt 0 ] || return 0
    if [ "${#files[@]}" -gt 1 ]; then
        warn "в $REPO_DIR/inventory/host_vars несколько конфигов, значения из них автоматически не переносятся"
        require_secrets_in_env "$REPO_DIR/inventory/host_vars"
        return 0
    fi
    existing="${files[0]}"
    command -v python3 > /dev/null 2>&1 || die "найдена прошлая установка ($existing), но для переноса её настроек нужен python3"

    ui_section "Найдена прошлая установка"
    note "$existing"
    note "Её домены и секреты переносятся в $ENV_FILE, пароль БД и ключи не изменятся."
    local imported="$WORK_DIR/imported.tsv"
    python3 - "$existing" > "$imported" <<'PY' || die "не удалось прочитать $existing"
import re
import sys

mapping = {
    "your_ip": "YOUR_IP",
    "matrix_domain": "DOMAIN",
    "matrix_server_fqn_matrix": "DOMAIN_MATRIX",
    "matrix_server_fqn_element": "DOMAIN_WEB_CLIENT",
    "matrix_element_admin_hostname": "DOMAIN_ADMIN_PANEL",
    "coturn_hostname": "DOMAIN_COTURN",
    "matrix_element_call_hostname": "DOMAIN_CALL",
    "ntfy_hostname": "DOMAIN_NTFY",
    "traefik_config_certificatesResolvers_acme_email": "ADMIN_EMAIL",
    "matrix_homeserver_generic_secret_key": "GENERIC_SECRET",
    "postgres_connection_password": "DB_PASSWORD",
    "coturn_turn_static_auth_secret": "COTURN_SECRET",
    "matrix_authentication_service_config_secrets_encryption": "MAS_ENC_KEY",
    "matrix_ketesa_enabled": "KETESA_ENABLED",
    "matrix_element_admin_enabled": "ELEMENT_ADMIN_ENABLED",
    "matrix_bridge_mautrix_telegram_api_id": "TG_API_ID",
    "matrix_bridge_mautrix_telegram_api_hash": "TG_API_HASH",
    "telegram_api_id": "TG_API_ID",
    "telegram_api_hash": "TG_API_HASH",
    "telegram_bridge_encryption_enabled": "TG_ENCRYPTION",
    "telegram_direct_media_enabled": "TG_DIRECT_MEDIA",
    "telegram_media_hostname": "TG_MEDIA_DOMAIN",
    "matrix_admin": "TG_ADMIN",
}
toggles = {"KETESA_ENABLED", "ELEMENT_ADMIN_ENABLED", "TG_ENCRYPTION", "TG_DIRECT_MEDIA"}
line_re = re.compile(r"""^([A-Za-z_][A-Za-z0-9_]*):\s*(?:"([^"]*)"|'([^']*)'|([^\s#]+))""")
found = {}
uses_proxy = False
with open(sys.argv[1], encoding="utf-8") as f:
    for line in f:
        m = line_re.match(line)
        if not m:
            continue
        key = m.group(1)
        value = next((g for g in m.groups()[1:] if g is not None), "")
        if key == "your_proxy_http_proxy" and value:
            uses_proxy = True
        if key in mapping and value and "{{" not in value and "$" not in value and '"' not in value:
            if mapping[key] in toggles:
                value = "true" if value.lower() in ("true", "yes", "on") else "false"
            found[mapping[key]] = value
found["NEED_XRAY"] = "yes" if uses_proxy else "no"
# Мост: на этом сервере (встроенная роль) или на отдельном (роль telegram-advanced)
with open(sys.argv[1], encoding="utf-8") as f:
    text = f.read()
if re.search(r"^matrix_bridge_mautrix_telegram_enabled:\s*true", text, re.M):
    found["TG_BRIDGE"] = "local"
elif re.search(r"^telegram_api_id:\s*[1-9]", text, re.M):
    found["TG_BRIDGE"] = "remote"
for key, value in found.items():
    print(f"{key}\t{value}")
PY
    while IFS=$'\t' read -r key value; do
        [ -n "$value" ] || continue
        if [ -z "$(env_get "$key")" ]; then
            env_set "$key" "$value"
        fi
    done < "$imported"

    # Адрес отдельного сервера моста - из inventory/hosts
    local hosts="$REPO_DIR/inventory/hosts"
    if [ -f "$hosts" ] && grep -qE '^\[telegram_bridge_servers\][[:space:]]*$' "$hosts"; then
        value="$(bridge_inventory_value "$hosts" ansible_host)"
        [ -n "$(env_get TG_HOST)" ] || [ -z "$value" ] || env_set TG_HOST "$value"
        value="$(bridge_inventory_value "$hosts" ansible_port)"
        [ -n "$(env_get TG_SSH_PORT)" ] || env_set TG_SSH_PORT "${value:-22}"
    fi

    require_secrets_in_env "$existing"
}

# Новый секрет при существующей установке сломает Postgres или MAS, поэтому не генерируем его, а останавливаемся
require_secrets_in_env() {
    local source="$1" key
    for key in GENERIC_SECRET DB_PASSWORD COTURN_SECRET MAS_ENC_KEY; do
        [ -n "$(env_get "$key")" ] \
            || die "на сервере есть прошлая установка ($source), но значение $key не найдено. Чтобы не сломать её, впишите его в $ENV_FILE вручную (формат: $key=\"значение\") и запустите скрипт снова"
    done
}

# ---------- вопросы: по одному, с возвратом назад и экраном проверки ----------

# Порядок вопросов. VLESS_LINK задаётся только при Xray; логин и пароль админа в .env не пишутся.
QUESTIONS=(YOUR_IP DOMAIN DOMAIN_MATRIX DOMAIN_WEB_CLIENT KETESA_ENABLED ELEMENT_ADMIN_ENABLED DOMAIN_ADMIN_PANEL
    DOMAIN_COTURN DOMAIN_CALL DOMAIN_NTFY
    ADMIN_EMAIL NEED_XRAY VLESS_LINK
    TG_BRIDGE TG_API_ID TG_API_HASH TG_HOST TG_SSH_PORT TG_ENCRYPTION TG_DIRECT_MEDIA TG_MEDIA_DOMAIN TG_ADMIN
    ADMIN_NICK ADMIN_PASS)
SUBDOMAINS=(DOMAIN_MATRIX DOMAIN_WEB_CLIENT DOMAIN_ADMIN_PANEL DOMAIN_COTURN DOMAIN_CALL DOMAIN_NTFY TG_MEDIA_DOMAIN)
# Поля, уже показанные в этом запуске: при возврате назад и движении вперёд они спрашиваются снова
declare -A ASKED_FIELDS=()
ADMIN_NICK=""
ADMIN_PASS=""
ADMIN_PASS_GENERATED=no
NEED_XRAY=""
VLESS_LINK=""
KETESA_ENABLED=""
ELEMENT_ADMIN_ENABLED=""
DOMAIN_ADMIN_PANEL=""
# Значения задаются через ask (printf -v) и читаются по имени в field_value
# shellcheck disable=SC2034
TG_BRIDGE=none TG_API_ID="" TG_API_HASH="" TG_HOST="" TG_SSH_PORT=22 TG_ENCRYPTION=false TG_DIRECT_MEDIA=false TG_MEDIA_DOMAIN="" TG_ADMIN=""
TG_ADMIN_DEFAULT=""
# yes - вопросы только о мосте (пункт панели): тогда спрашивается и администратор моста
BRIDGE_ONLY=no

field_label() {
    case "$1" in
        YOUR_IP) echo "IP сервера" ;;
        DOMAIN) echo "Основной домен" ;;
        DOMAIN_MATRIX) echo "Matrix" ;;
        DOMAIN_WEB_CLIENT) echo "Element Web" ;;
        DOMAIN_ADMIN_PANEL) echo "Поддомен Element Admin" ;;
        DOMAIN_COTURN) echo "Coturn" ;;
        DOMAIN_CALL) echo "Element Call" ;;
        DOMAIN_NTFY) echo "ntfy" ;;
        ADMIN_EMAIL) echo "Email (Let's Encrypt)" ;;
        NEED_XRAY) echo "Xray-прокси" ;;
        KETESA_ENABLED) echo "Админка Ketesa" ;;
        ELEMENT_ADMIN_ENABLED) echo "Админка Element Admin" ;;
        VLESS_LINK) echo "Ссылка vless://" ;;
        ADMIN_NICK) echo "Логин админа" ;;
        ADMIN_PASS) echo "Пароль админа" ;;
        TG_BRIDGE) echo "Мост Telegram" ;;
        TG_API_ID) echo "Telegram api_id" ;;
        TG_API_HASH) echo "Telegram api_hash" ;;
        TG_HOST) echo "Сервер моста" ;;
        TG_SSH_PORT) echo "SSH-порт сервера моста" ;;
        TG_ENCRYPTION) echo "Шифрование личных чатов" ;;
        TG_DIRECT_MEDIA) echo "Прямые медиа" ;;
        TG_MEDIA_DOMAIN) echo "Домен прямых медиа" ;;
        TG_ADMIN) echo "Администратор моста" ;;
    esac
}

field_value() {
    case "$1" in
        NEED_XRAY) if [ "$NEED_XRAY" = yes ]; then echo "да"; else echo "нет"; fi ;;
        KETESA_ENABLED | ELEMENT_ADMIN_ENABLED | TG_ENCRYPTION | TG_DIRECT_MEDIA) if [ "${!1}" = true ]; then echo "да"; else echo "нет"; fi ;;
        TG_BRIDGE) bridge_mode_label "$TG_BRIDGE" ;;
        TG_API_HASH) echo "задан" ;;
        VLESS_LINK) if [ "${#VLESS_LINK}" -gt 40 ]; then echo "${VLESS_LINK:0:40}…"; else echo "$VLESS_LINK"; fi ;;
        ADMIN_PASS) if [ "$ADMIN_PASS_GENERATED" = yes ]; then echo "будет сгенерирован"; else echo "задан"; fi ;;
        *) echo "${!1}" ;;
    esac
}

# IP, с которого сервер выходит в интернет. Только подсказка: за NAT это будет внутренний адрес.
detect_ip() {
    ip -4 route get 1.1.1.1 2> /dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p' | head -1
}

# ask ПЕРЕМЕННАЯ "вопрос" проверка [нормализация] [по умолчанию] [mask] -> 0 / 2 (назад)
# Значение из .env не спрашивается, если поле ещё не показывалось в этом запуске.
# mask - после ответа показать «задан» вместо значения.
ask() {
    local var="$1" prompt="$2" check="$3" normalize="${4:-}" default="${5:-}" mask="${6:-}" value rc
    value="$(env_get "$var")"
    if [ -n "$value" ] && [ -z "${ASKED_FIELDS[$var]:-}" ]; then
        printf -v "$var" '%s' "$value"
        return 0
    fi
    [ -z "$value" ] || default="$value"
    ASKED_FIELDS[$var]=1
    while true; do
        rc=0
        value="$(prompt_value "$prompt" "$default")" || rc=$?
        [ "$rc" -ne "$BACK" ] || return "$BACK"
        [ "$rc" -eq 0 ] || exit "$rc"
        [ -z "$normalize" ] || value="$("$normalize" "$value")"
        if "$check" "$value"; then
            break
        fi
        ui_invalid "Некорректное значение${value:+: $value}. Попробуйте ещё раз (назад: $(back_hint))."
        [ "$UI" != gum ] || default="$value"
    done
    env_set "$var" "$value"
    printf -v "$var" '%s' "$value"
    if [ -n "$mask" ]; then
        ui_answer "$(field_label "$var")" "задан"
    else
        ui_answer "$(field_label "$var")" "$value"
    fi
}

back_hint() {
    if [ "$UI" = gum ]; then echo "Esc"; else echo "<"; fi
}

# Смена основного домена переносит поддомены вида x.старый-домен на новый
ask_domain() {
    local old rc=0 var value
    old="$(env_get DOMAIN)"
    ask DOMAIN "Основной домен (например, example.com)" is_domain normalize_domain || rc=$?
    [ "$rc" -eq 0 ] || return "$rc"
    if [ -n "$old" ] && [ "$old" != "$DOMAIN" ]; then
        for var in "${SUBDOMAINS[@]}"; do
            value="$(env_get "$var")"
            if [ -n "$value" ] && [ "${value%."$old"}" != "$value" ]; then
                env_set "$var" "${value%."$old"}.$DOMAIN"
            fi
        done
    fi
}

ask_xray() {
    local value rc=0
    value="$(env_get NEED_XRAY)"
    if [ -n "$value" ] && [ -z "${ASKED_FIELDS[NEED_XRAY]:-}" ]; then
        NEED_XRAY="$value"
        return 0
    fi
    ASKED_FIELDS[NEED_XRAY]=1
    ui_yes_no "Сервер в РФ и нужен Xray-прокси (потребуется ссылка vless://)?" "${value:-no}" || rc=$?
    case "$rc" in
        0) NEED_XRAY=yes ;;
        1) NEED_XRAY=no ;;
        *) return "$rc" ;;
    esac
    env_set NEED_XRAY "$NEED_XRAY"
    ui_answer "Xray-прокси" "$(field_value NEED_XRAY)"
}

# Нужен ли вопрос сейчас: ссылка - только при Xray, поддомен Element Admin - только если она включена
field_applicable() {
    case "$1" in
        VLESS_LINK) [ "$NEED_XRAY" = yes ] ;;
        DOMAIN_ADMIN_PANEL) [ "$ELEMENT_ADMIN_ENABLED" = true ] ;;
        TG_API_ID | TG_API_HASH | TG_ENCRYPTION) [ "$TG_BRIDGE" = local ] || [ "$TG_BRIDGE" = remote ] ;;
        TG_HOST | TG_SSH_PORT | TG_DIRECT_MEDIA) [ "$TG_BRIDGE" = remote ] ;;
        TG_MEDIA_DOMAIN) [ "$TG_BRIDGE" = remote ] && [ "$TG_DIRECT_MEDIA" = true ] ;;
        TG_ADMIN) [ "$BRIDGE_ONLY" = yes ] && { [ "$TG_BRIDGE" = local ] || [ "$TG_BRIDGE" = remote ]; } ;;
        # В панели спрашивается только мост
        TG_BRIDGE) return 0 ;;
        *) [ "$BRIDGE_ONLY" != yes ] ;;
    esac
}

# ask_toggle ПЕРЕМЕННАЯ "вопрос" по_умолчанию(true|false) -> 0 / 2 (назад). Значение: true или false.
# Если ответы идут не с клавиатуры, вопрос не задаётся (порядок ответов через stdin не меняется).
ask_toggle() {
    local var="$1" question="$2" def="$3" value rc=0
    value="$(env_get "$var")"
    if [ -n "$value" ] && [ -z "${ASKED_FIELDS[$var]:-}" ]; then
        printf -v "$var" '%s' "$value"
        return 0
    fi
    if [ ! -t 0 ] && [ -z "$value" ]; then
        env_set "$var" "$def"
        printf -v "$var" '%s' "$def"
        return 0
    fi
    ASKED_FIELDS[$var]=1
    if [ "${value:-$def}" = true ]; then def=yes; else def=no; fi
    ui_yes_no "$question" "$def" || rc=$?
    case "$rc" in
        0) value=true ;;
        1) value=false ;;
        *) return "$rc" ;;
    esac
    env_set "$var" "$value"
    printf -v "$var" '%s' "$value"
    ui_answer "$(field_label "$var")" "$(field_value "$var")"
}

ask_admin_nick() {
    local value rc
    while true; do
        rc=0
        value="$(prompt_value "Логин админа (строчные латинские буквы, цифры, символы ._=-)" "${ADMIN_NICK:-admin}")" || rc=$?
        [ "$rc" -ne "$BACK" ] || return "$BACK"
        [ "$rc" -eq 0 ] || exit "$rc"
        if is_nick "$value"; then
            break
        fi
        ui_invalid "Некорректный логин. Попробуйте ещё раз (назад: $(back_hint))."
    done
    ADMIN_NICK="$value"
    ui_answer "Логин админа" "$value"
}

ask_admin_pass() {
    local value rc
    while true; do
        rc=0
        value="$(prompt_value "Пароль админа (от 12 символов: строчные и заглавные буквы, цифры; Enter — сгенерировать)" "" secret)" || rc=$?
        [ "$rc" -ne "$BACK" ] || return "$BACK"
        [ "$rc" -eq 0 ] || exit "$rc"
        if [ -z "$value" ]; then
            ADMIN_PASS="$(openssl rand -base64 24 | tr -d '+/=\n')"
            ADMIN_PASS_GENERATED=yes
            ui_answer "Пароль админа" "будет сгенерирован и показан в конце"
            [ "$UI" = gum ] || echo "  Пароль сгенерирован, он будет показан в конце установки."
            return 0
        fi
        if is_password "$value"; then
            break
        fi
        ui_invalid "Слишком простой пароль: нужно от 12 символов, строчные и заглавные буквы, цифры, без пробелов (назад: $(back_hint))."
    done
    ADMIN_PASS="$value"
    ADMIN_PASS_GENERATED=no
    ui_answer "Пароль админа" "задан"
}

# ask_field ПОЛЕ -> 0 ответ принят, 2 назад, 3 вопрос сейчас не нужен
ask_field() {
    case "$1" in
        YOUR_IP) ask YOUR_IP "IP (v4) сервера" is_ipv4 "" "$(detect_ip)" ;;
        DOMAIN) ask_domain ;;
        DOMAIN_MATRIX) ask DOMAIN_MATRIX "Поддомен для Matrix" is_domain normalize_domain "mat.$DOMAIN" ;;
        DOMAIN_WEB_CLIENT) ask DOMAIN_WEB_CLIENT "Поддомен для Element Web" is_domain normalize_domain "elem.$DOMAIN" ;;
        KETESA_ENABLED) ask_toggle KETESA_ENABLED "Установить админку Ketesa (бывший synapse-admin)? Откроется на https://$DOMAIN_MATRIX/synapse-admin/" true ;;
        ELEMENT_ADMIN_ENABLED) ask_toggle ELEMENT_ADMIN_ENABLED "Установить админку Element Admin? Нужен отдельный поддомен" true ;;
        DOMAIN_ADMIN_PANEL)
            field_applicable DOMAIN_ADMIN_PANEL || return "$SKIP"
            ask DOMAIN_ADMIN_PANEL "Поддомен для Element Admin" is_domain normalize_domain "admin.$DOMAIN"
            ;;
        DOMAIN_COTURN) ask DOMAIN_COTURN "Поддомен для Coturn (звонки 1-на-1)" is_domain normalize_domain "turn.$DOMAIN" ;;
        DOMAIN_CALL) ask DOMAIN_CALL "Поддомен для Element Call (групповые звонки)" is_domain normalize_domain "call.$DOMAIN" ;;
        DOMAIN_NTFY) ask DOMAIN_NTFY "Поддомен для ntfy (push-уведомления)" is_domain normalize_domain "ntfy.$DOMAIN" ;;
        ADMIN_EMAIL) ask ADMIN_EMAIL "Email для уведомлений Let's Encrypt" is_email ;;
        NEED_XRAY) ask_xray ;;
        VLESS_LINK)
            if ! field_applicable VLESS_LINK; then
                VLESS_LINK=""
                return "$SKIP"
            fi
            ask VLESS_LINK "Ссылка vless:// для Xray" is_vless
            ;;
        ADMIN_NICK) ask_admin_nick ;;
        ADMIN_PASS) ask_admin_pass ;;
        TG_BRIDGE) ask_bridge_mode ;;
        TG_API_ID)
            field_applicable TG_API_ID || return "$SKIP"
            ask TG_API_ID "Telegram api_id (со страницы https://my.telegram.org/apps)" is_api_id normalize_token
            ;;
        TG_API_HASH)
            field_applicable TG_API_HASH || return "$SKIP"
            ask TG_API_HASH "Telegram api_hash (там же, 32 символа)" is_api_hash normalize_token "" mask
            ;;
        TG_HOST)
            field_applicable TG_HOST || return "$SKIP"
            ask TG_HOST "IP или домен сервера моста (не этот сервер; Telegram должен быть доступен с него)" is_bridge_host normalize_domain
            ;;
        TG_SSH_PORT)
            field_applicable TG_SSH_PORT || return "$SKIP"
            ask TG_SSH_PORT "SSH-порт сервера моста" is_port "" 22
            ;;
        TG_ENCRYPTION)
            field_applicable TG_ENCRYPTION || return "$SKIP"
            ask_toggle TG_ENCRYPTION "Шифровать новые личные чаты Telegram в Matrix? (Element будет предупреждать, что подпись отправителя не проверена)" false
            ;;
        TG_DIRECT_MEDIA)
            field_applicable TG_DIRECT_MEDIA || return "$SKIP"
            ask_toggle TG_DIRECT_MEDIA "Прямые медиа: файлы каналов не копировать в Synapse, а отдавать по запросу? Нужен отдельный поддомен" false
            ;;
        TG_MEDIA_DOMAIN)
            field_applicable TG_MEDIA_DOMAIN || return "$SKIP"
            ask TG_MEDIA_DOMAIN "Поддомен прямых медиа (DNS-запись на ЭТОТ сервер Matrix)" is_domain normalize_domain "tm.$DOMAIN"
            ;;
        TG_ADMIN)
            field_applicable TG_ADMIN || return "$SKIP"
            ask TG_ADMIN "Администратор моста (Matrix ID, меняет настройки общих комнат)" is_matrix_id "" "$TG_ADMIN_DEFAULT"
            ;;
    esac
}

# Предыдущий вопрос для "назад" (результат в PREV_INDEX). Он открывается с сохранённым значением,
# даже если в этом запуске не задавался (например, ответ остался в файле параметров с прошлого раза).
PREV_INDEX=0
prev_question() {
    local i="$1" j f
    for ((j = i - 1; j >= 0; j--)); do
        f="${QUESTIONS[$j]}"
        field_applicable "$f" || continue
        ASKED_FIELDS[$f]=1
        PREV_INDEX="$j"
        return 0
    done
    ui_invalid "Это первый вопрос, назад некуда."
    ASKED_FIELDS[${QUESTIONS[$i]}]=1
    PREV_INDEX="$i"
}

# Проходит вопросы с индекса $1. "Назад" возвращает к предыдущему вопросу.
run_questions() {
    local i="$1" n="${#QUESTIONS[@]}" rc
    while [ "$i" -lt "$n" ]; do
        rc=0
        ask_field "${QUESTIONS[$i]}" || rc=$?
        if [ "$rc" -eq "$BACK" ]; then
            prev_question "$i"
            i="$PREV_INDEX"
            continue
        fi
        [ "$rc" -eq 0 ] || [ "$rc" -eq "$SKIP" ] || exit "$rc"
        i=$((i + 1))
    done
}

# Таблица параметров. show_answers [numbered] - с номерами строк для правки в текстовом режиме.
# Список показанных полей остаётся в SHOWN_FIELDS.
SHOWN_FIELDS=()
show_answers() {
    local numbered="${1:-}" rows=() f i
    SHOWN_FIELDS=()
    for f in "${QUESTIONS[@]}"; do
        field_applicable "$f" || continue
        SHOWN_FIELDS+=("$f")
    done
    for i in "${!SHOWN_FIELDS[@]}"; do
        if [ -n "$numbered" ]; then
            rows+=("$((i + 1)). $(field_label "${SHOWN_FIELDS[$i]}")" "$(field_value "${SHOWN_FIELDS[$i]}")")
        else
            rows+=("$(field_label "${SHOWN_FIELDS[$i]}")" "$(field_value "${SHOWN_FIELDS[$i]}")")
        fi
    done
    ui_table "${rows[@]}"
}

# Экран проверки: 0 начать, 2 назад к последнему вопросу. review_answers ["подпись кнопки начала"]
review_answers() {
    local fields=() f i choice rc start="${1:-Начать установку}"
    while true; do
        ui_section "Проверьте параметры"
        if [ "$UI" = gum ]; then show_answers; else show_answers numbered; fi
        fields=("${SHOWN_FIELDS[@]}")

        if [ "$UI" = gum ]; then
            rc=0
            choice="$("$GUM" choose --header "Всё верно?" -- "$start" "Исправить значение" "← Назад")" || rc=$?
            case "$rc" in
                0) ;;
                1)
                    clear_gum_line
                    return "$BACK"
                    ;;
                *) cancel_input ;;
            esac
            case "$choice" in
                "$start") return 0 ;;
                "← Назад") return "$BACK" ;;
            esac
            local labels=()
            for f in "${fields[@]}"; do labels+=("$(field_label "$f") — $(field_value "$f")"); done
            rc=0
            choice="$("$GUM" choose --header "Что исправить?" -- "${labels[@]}")" || rc=$?
            [ "$rc" -le 1 ] || cancel_input
            [ "$rc" -eq 0 ] || clear_gum_line
            [ "$rc" -eq 0 ] || continue
            for i in "${!labels[@]}"; do
                [ "${labels[$i]}" != "$choice" ] || f="${fields[$i]}"
            done
        else
            read -r -p "Enter — ${start,,}, номер — исправить, < — назад: " choice || die "ввод закончился, а ответы ещё нужны"
            [ -n "$choice" ] || return 0
            [ "$choice" != "<" ] || return "$BACK"
            if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt "${#fields[@]}" ]; then
                ui_invalid "Нет такого номера."
                continue
            fi
            f="${fields[$((choice - 1))]}"
        fi
        edit_field "$f"
    done
}

# Исправление одного поля с экрана проверки. "Назад" здесь просто возвращает к экрану.
edit_field() {
    local f="$1" rc=0
    ASKED_FIELDS[$f]=1
    ask_field "$f" || rc=$?
    [ "$rc" -eq 0 ] || [ "$rc" -eq "$BACK" ] || exit "$rc"
    # Изменение могло сделать нужными новые вопросы (включили Xray - нужна ссылка, выбрали мост -
    # нужны его параметры): задаём те, на которые ещё нет ответа
    local need
    for need in "${QUESTIONS[@]}"; do
        case "$need" in ADMIN_NICK | ADMIN_PASS) continue ;; esac
        field_applicable "$need" || continue
        [ -z "$(env_get "$need")" ] || continue
        ASKED_FIELDS[$need]=1
        while true; do
            rc=0
            ask_field "$need" || rc=$?
            [ "$rc" -eq "$BACK" ] || break
        done
    done
}

collect_input() {
    ui_section "Параметры сервера"
    note "Ответы сохраняются в $ENV_FILE. Enter принимает значение по умолчанию, $(back_hint) — назад."
    local rc
    run_questions 0
    # Ответы не с клавиатуры (файл, другая программа): таблица только для журнала, без ожидания -
    # иначе экран проверки съел бы следующую строку ввода.
    if [ ! -t 0 ]; then
        ui_section "Параметры установки"
        show_answers
    fi
    # Экран проверки - при ручном вводе
    while [ -t 0 ]; do
        rc=0
        review_answers || rc=$?
        [ "$rc" -eq "$BACK" ] || break
        # Назад с экрана проверки - к последнему вопросу
        run_questions "$((${#QUESTIONS[@]} - 1))"
    done

    if [ "$TG_BRIDGE" = remote ] && ! ensure_bridge_ssh; then
        TG_BRIDGE=none
        env_set TG_BRIDGE none
        warn "мост Telegram не будет установлен: нет доступа к серверу моста по SSH. Его можно поставить позже в панели: sudo matrix-up"
    fi
    if [ "$TG_BRIDGE" != remote ] && [ -d "$BRIDGE_WSPROXY_DIR" ]; then
        warn "на сервере есть мост Telegram на отдельном сервере ($BRIDGE_WSPROXY_DIR), а vars.yml пересоздаётся из шаблона: его подключение к Synapse пропадёт. Чтобы сохранить мост, прервите установку (Ctrl+C) и выберите в вопросе о мосте «На отдельном сервере»"
    fi

    # Секреты: генерируются один раз, потом берутся из .env
    ensure_secret GENERIC_SECRET
    ensure_secret DB_PASSWORD
    ensure_secret COTURN_SECRET
    ensure_secret MAS_ENC_KEY
}

# ---------- шаг 2: базовые пакеты и swap ----------

install_base() {
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get upgrade -y
    apt-get install -y curl git python3 python3-pip wget ufw openssl software-properties-common
}

setup_swap() {
    if swapon --show=NAME --noheadings | grep -qx /swapfile; then
        note "Swap-файл уже включён"
        return 0
    fi
    if [ ! -f /swapfile ]; then
        fallocate -l 4G /swapfile
        chmod 600 /swapfile
        mkswap /swapfile
    fi
    swapon /swapfile
    grep -qs '^/swapfile ' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
    # Отдельный файл в sysctl.d: повторный запуск его просто перезапишет
    echo 'vm.swappiness=10' > /etc/sysctl.d/99-matrix-swappiness.conf
    sysctl -p /etc/sysctl.d/99-matrix-swappiness.conf > /dev/null
}

# ---------- шаг 3: Xray (только если нужен) ----------

setup_xray() {
    download "$RAW_BASE/scripts/dependency/xray_outbound_parsing.js" "$WORK_DIR/xray_outbound_parsing.js"
    download "$RAW_BASE/scripts/dependency/xray_util.js" "$WORK_DIR/xray_util.js"
    download "$RAW_BASE/scripts/dependency/xray_configurator.js" "$WORK_DIR/xray_configurator.js"
    download "$RAW_BASE/configs/xray.json" "$WORK_DIR/xray.json"

    apt-get install -y nodejs npm

    # Собираем конфиг из vless-ссылки. Ошибка останавливает скрипт здесь, а не уходит в установку.
    (cd "$WORK_DIR" && node xray_configurator.js "$VLESS_LINK") || die "не удалось собрать конфиг Xray из ссылки"
    [ -s "$WORK_DIR/config.json" ] || die "файл config.json не создан"

    # Сначала ставим Xray (он создаёт /usr/local/etc/xray), потом кладём конфиг, и только потом запускаем.
    bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
    mkdir -p /usr/local/share/xray
    run_with_retry "wget -q https://github.com/runetfreedom/russia-v2ray-rules-dat/releases/latest/download/geosite.dat -O /usr/local/share/xray/geosite.dat"
    run_with_retry "wget -q https://github.com/runetfreedom/russia-v2ray-rules-dat/releases/latest/download/geoip.dat -O /usr/local/share/xray/geoip.dat"

    /usr/local/bin/xray run -test -config "$WORK_DIR/config.json" || die "конфиг Xray не прошёл проверку"
    install -m 644 "$WORK_DIR/config.json" /usr/local/etc/xray/config.json
    systemctl enable xray
    systemctl restart xray

    # restart возвращается раньше, чем Xray откроет порты. Дальше всё качается через прокси,
    # поэтому ждём порты здесь, иначе загрузки падают с "connection refused".
    echo "Ждём, пока Xray откроет порты 10808 и ${PROXY_PORT}..."
    if ! wait_for_port 127.0.0.1 "$PROXY_PORT" 30 || ! wait_for_port 127.0.0.1 10808 5; then
        systemctl status xray --no-pager -l || true
        journalctl -u xray -n 30 --no-pager || true
        die "Xray не открыл порты за 30 секунд (журнал выше)"
    fi

    # Проверяем, что через прокси реально есть выход. Неудача не фатальна: VLESS-сервер мог
    # прилечь на минуту, а загрузки дальше сами делают повторы.
    if run_with_retry "curl -fsS -o /dev/null --max-time 15 -x http://127.0.0.1:${PROXY_PORT} https://github.com" 3; then
        note "Xray работает, выход через прокси проверен"
    else
        warn "Xray запущен, но через него не открывается https://github.com. Проверьте ссылку vless:// и доступность вашего VLESS-сервера. Установка продолжится, но загрузки могут падать."
    fi
}

setup_proxy() {
    local host_proxy="http://127.0.0.1:${PROXY_PORT}"
    local no_proxy_list="localhost,127.0.0.1,::1,${YOUR_IP},${DOMAIN},.${DOMAIN},172.16.0.0/12,10.0.0.0/8,fd42:f167:100f::/48"

    # Для текущей сессии скрипта
    export http_proxy="$host_proxy" https_proxy="$host_proxy" ftp_proxy="$host_proxy" no_proxy="$no_proxy_list"
    export HTTP_PROXY="$host_proxy" HTTPS_PROXY="$host_proxy" FTP_PROXY="$host_proxy" NO_PROXY="$no_proxy_list"

    # /etc/environment: убираем только строки прокси, остальное сохраняем
    local env_tmp
    env_tmp="$(mktemp "$WORK_DIR/environment.XXXXXX")"
    grep -viE '^(http|https|ftp|no)_proxy=' /etc/environment > "$env_tmp" || true
    cat >> "$env_tmp" <<EOF
http_proxy="$host_proxy"
https_proxy="$host_proxy"
ftp_proxy="$host_proxy"
no_proxy="$no_proxy_list"
HTTP_PROXY="$host_proxy"
HTTPS_PROXY="$host_proxy"
FTP_PROXY="$host_proxy"
NO_PROXY="$no_proxy_list"
EOF
    install -m 644 "$env_tmp" /etc/environment

    # Прокси для докера. Docker перезапускается, только если настройка действительно изменилась.
    local dropin=/etc/systemd/system/docker.service.d/http-proxy.conf dropin_tmp
    dropin_tmp="$(mktemp "$WORK_DIR/docker-proxy.XXXXXX")"
    cat > "$dropin_tmp" <<EOF
[Service]
Environment="HTTP_PROXY=http://${DOCKER_BRIDGE_IP}:${PROXY_PORT}"
Environment="HTTPS_PROXY=http://${DOCKER_BRIDGE_IP}:${PROXY_PORT}"
Environment="NO_PROXY=localhost,127.0.0.1,::1,${YOUR_IP},${DOMAIN},.${DOMAIN},172.16.0.0/12,10.0.0.0/8,fd42:f167:100f::/48"
EOF
    if ! cmp -s "$dropin_tmp" "$dropin"; then
        mkdir -p "$(dirname "$dropin")"
        install -m 644 "$dropin_tmp" "$dropin"
        DOCKER_RESTART=yes
    fi
}

# ---------- шаг 4: docker, ansible, репозиторий плейбука ----------

DOCKER_RESTART=no

install_docker() {
    # Установщик get.docker.com при уже установленном Docker ждёт 20 секунд и переустанавливает пакеты,
    # а перезапуск Docker останавливает все контейнеры Matrix - поэтому повторно не запускаем.
    if command -v docker > /dev/null 2>&1 && systemctl cat docker.service > /dev/null 2>&1; then
        note "Docker уже установлен: $(docker --version 2> /dev/null | sed 's/,.*//')"
    else
        run_with_retry "curl -fsSL https://get.docker.com | sh"
        DOCKER_RESTART=yes
    fi
    systemctl enable --now docker
    if [ "$DOCKER_RESTART" = yes ]; then
        systemctl daemon-reload
        systemctl restart docker
    fi
    if [ "$ELEMENT_ADMIN_ENABLED" = true ]; then
        echo "Подготовка образа Element Admin..."
        run_with_retry "docker pull oci.element.io/element-admin:latest"
    fi
}

# Свежий just с just.systems в /usr/local/bin (он в PATH раньше /usr/bin)
install_just_upstream() {
    run_with_retry "curl --proto '=https' --tlsv1.2 -fsS https://just.systems/install.sh | bash -s -- --force --to /usr/local/bin" 5
}

install_ansible() {
    run_with_retry "add-apt-repository --yes --update ppa:ansible/ansible" 5
    apt-get install -y ansible
    # just: сначала из репозитория Ubuntu (24.04+), иначе с just.systems.
    # Подходит ли версия к justfile плейбука, проверяется после клонирования (ensure_just_works).
    if ! command -v just > /dev/null 2>&1; then
        apt-get install -y just || install_just_upstream || die "не удалось установить just"
    fi
}

# Старый just (например, из репозитория Ubuntu) может не понять justfile плейбука - тогда ставим свежий
ensure_just_works() {
    if just --list > /dev/null 2>&1; then
        return 0
    fi
    note "just $(just --version 2> /dev/null | awk '{print $2}') не читает justfile плейбука, ставим свежую версию"
    install_just_upstream || die "не удалось установить подходящую версию just"
    hash -r
    just --list > /dev/null || die "just не читает justfile плейбука в $REPO_DIR"
}

# Плейбук фиксируется на PLAYBOOK_COMMIT. Уже установленный плейбук новее этой версии
# не откатывается: откат может сломать базу данных Synapse.
clone_playbook() {
    if [ ! -d "$REPO_DIR/.git" ]; then
        [ ! -e "$REPO_DIR" ] || die "$REPO_DIR существует, но это не git-репозиторий. Переименуйте его и запустите скрипт снова"
        local partial="$REPO_DIR.partial"
        run_with_retry "rm -rf '$partial' && git clone -q '$PLAYBOOK_REPO' '$partial'"
        mv "$partial" "$REPO_DIR"
        git -C "$REPO_DIR" checkout -q "$PLAYBOOK_COMMIT"
        note "Плейбук зафиксирован на версии $PLAYBOOK_VERSION"
    else
        run_with_retry "git -C '$REPO_DIR' fetch -q origin"
        if git -C "$REPO_DIR" merge-base --is-ancestor "$PLAYBOOK_COMMIT" HEAD; then
            note "Плейбук уже не старше версии $PLAYBOOK_VERSION, оставлен как есть"
        else
            git -C "$REPO_DIR" checkout -q "$PLAYBOOK_COMMIT" \
                || die "не удалось переключить плейбук на $PLAYBOOK_COMMIT: в $REPO_DIR есть локальные изменения"
            note "Плейбук переключён на версию $PLAYBOOK_VERSION"
        fi
    fi
    cd "$REPO_DIR" || die "директория $REPO_DIR недоступна"
    # 'just update' сделал бы git pull и ушёл с зафиксированной версии, поэтому только роли
    ensure_just_works
    run_with_retry "just roles"
}

# ---------- шаг 5: inventory и vars.yml из шаблона ----------

render_inventory() {
    mkdir -p "inventory/host_vars/$DOMAIN_MATRIX"
    printf '[matrix_servers]\n%s ansible_host=127.0.0.1 ansible_connection=local\n' "$DOMAIN_MATRIX" > inventory/hosts

    download "$RAW_BASE/configs/vars.yml" "$WORK_DIR/vars.yml.tpl"
    local out="inventory/host_vars/$DOMAIN_MATRIX/vars.yml"

    # Прошлый vars.yml (возможно, с ручными правками) сохраняем рядом
    if [ -f "$out" ]; then
        local backup
        backup="$out.bak-$(date +%Y%m%d-%H%M%S)"
        cp -p "$out" "$backup"
        note "Прошлый vars.yml сохранён: $REPO_DIR/$backup"
    fi

    python3 - "$WORK_DIR/vars.yml.tpl" "$ENV_FILE" "$out" "$NEED_XRAY" "$ELEMENT_ADMIN_ENABLED" <<'PY' || die "не удалось собрать vars.yml"
import re
import sys

template_path, env_path, out_path, need_xray, element_admin = sys.argv[1:6]

values = {}
with open(env_path, encoding="utf-8") as f:
    for line in f:
        m = re.match(r'^([A-Z_][A-Z0-9_]*)="(.*)"$', line.rstrip("\n"))
        if m:
            values[m.group(1)] = m.group(2)

# Блоки между маркерами "# @ИМЯ_BEGIN" и "# @ИМЯ_END" попадают в файл, только если они нужны
keep = {"XRAY": need_xray == "yes", "ELEMENT_ADMIN": element_admin == "true"}
block = re.compile(r"^# @([A-Z_]+)_(BEGIN|END)$")
kept, skipping = [], False
with open(template_path, encoding="utf-8") as f:
    for line in f:
        m = block.match(line.strip())
        if m and m.group(1) in keep:
            skipping = m.group(2) == "BEGIN" and not keep[m.group(1)]
            continue
        if not skipping:
            kept.append(line)

text = "".join(kept)
placeholder = re.compile(r"\$\{([A-Z_][A-Z0-9_]*)\}")
missing = sorted({name for name in placeholder.findall(text) if not values.get(name)})
if missing:
    sys.exit("В файле параметров не заполнены переменные: " + ", ".join(missing))
text = placeholder.sub(lambda m: values[m.group(1)], text)

with open(out_path, "w", encoding="utf-8") as f:
    f.write(text)
PY
    chmod 600 "$out"

    # Мост Telegram: блок настроек в vars.yml и сервер моста в inventory
    if [ "$TG_BRIDGE" = local ] || [ "$TG_BRIDGE" = remote ]; then
        BRIDGE_VARS_FILE="$out"
        bridge_prepare_vars
    fi
}

# ---------- шаг 6: firewall ----------

# Порты SSH: из конфига sshd, из ssh.socket (Ubuntu 22.10+), из прослушиваемых sshd
# сокетов и из текущего подключения. Если ничего не нашли, считаем, что это 22.
detect_ssh_ports() {
    {
        if command -v sshd > /dev/null 2>&1; then
            # При запуске через ssh.socket каталога /run/sshd может не быть, и sshd -T падает
            mkdir -p /run/sshd 2> /dev/null || true
            sshd -T 2> /dev/null | awk '$1 == "port" {print $2}'
        fi
        systemctl show ssh.socket -p Listen --value 2> /dev/null \
            | grep -oE ':[0-9]+ ' | tr -d ': '
        ss -Htlnp 2> /dev/null | awk '/"sshd/ {sub(/.*:/, "", $4); print $4}'
        if [ -n "${SSH_CONNECTION:-}" ]; then
            awk '{print $4}' <<< "$SSH_CONNECTION"
        fi
    } | grep -xE '[0-9]{1,5}' | awk '$1 >= 1 && $1 <= 65535' | sort -un
}

setup_firewall() {
    local rule ssh_ports port
    ssh_ports="$(detect_ssh_ports || true)"
    [ -n "$ssh_ports" ] || ssh_ports=22
    for port in $ssh_ports; do
        ufw allow "$port/tcp"
    done
    note "SSH: открыт порт $(printf '%s\n' "$ssh_ports" | paste -sd, -)"
    for rule in 80/tcp 443/tcp 3478/tcp 3478/udp 5349/tcp 5349/udp \
                7880/tcp 7881/tcp 7882/udp 8448/tcp 49152:49652/udp; do
        ufw allow "$rule"
    done
    if [ "$NEED_XRAY" = yes ]; then
        ufw allow from 172.16.0.0/12 to any port 10808 proto tcp
        ufw allow from 172.16.0.0/12 to any port "$PROXY_PORT" proto tcp
    fi
    ufw --force enable
}

# ---------- шаг 7: установка плейбука и админ ----------

ADMIN_REGISTERED=no


setup_xray_and_proxy() {
    setup_xray
    setup_proxy
}

install_matrix() {
    # Повторы помогают при сетевых сбоях. Ошибки DNS и сертификатов они не лечат,
    # поэтому попыток мало, а при неудаче выводим, что проверить.
    run_with_retry "ansible-playbook -i inventory/hosts setup.yml --tags=install-all,start" 3 \
        || die "установка Matrix не удалась. Частые причины:
  - DNS-записи доменов ($DOMAIN, $DOMAIN_MATRIX, $DOMAIN_WEB_CLIENT${DOMAIN_ADMIN_PANEL:+, $DOMAIN_ADMIN_PANEL}, $DOMAIN_COTURN, $DOMAIN_CALL, $DOMAIN_NTFY) не указывают на $YOUR_IP;
  - порты 80 и 443 недоступны из интернета, и Let's Encrypt не может выдать сертификаты.
После исправления повторите: cd $REPO_DIR && sudo ansible-playbook -i inventory/hosts setup.yml --tags=install-all,start
Или запустите этот скрипт снова: значения и секреты возьмутся из $ENV_FILE"
}

register_admin() {
    # Пароль передаётся файлом, а не в командной строке (в командной строке он виден в ps)
    local vars_file="$WORK_DIR/admin-vars.json"
    (umask 077 && python3 -c 'import json,sys; print(json.dumps({"username": sys.argv[1], "password": sys.argv[2], "admin": "yes"}))' "$ADMIN_NICK" "$ADMIN_PASS" > "$vars_file")
    # Ошибка регистрации не должна обесценивать уже выполненную установку
    if ansible-playbook -i inventory/hosts setup.yml --extra-vars "@$vars_file" --tags=register-user; then
        ADMIN_REGISTERED=yes
    else
        warn "администратор не зарегистрирован: такой пользователь уже есть, или MAS счёл пароль слишком простым"
    fi
    rm -f "$vars_file"
}

print_summary() {
    local config="$REPO_DIR/inventory/host_vars/$DOMAIN_MATRIX/vars.yml" pass_shown="$ADMIN_PASS"
    # Пароль, который не удалось применить, показывать нельзя: у существующего админа остался старый
    [ "$ADMIN_REGISTERED" = yes ] || pass_shown="не применён (см. предупреждение ниже)"
    ui_section "Установка завершена!"
    ui_table \
        "Matrix (homeserver)" "https://$DOMAIN_MATRIX" \
        "Element Web" "https://$DOMAIN_WEB_CLIENT" \
        "Админка Ketesa" "$(if [ "$KETESA_ENABLED" = true ]; then echo "https://$DOMAIN_MATRIX/synapse-admin/"; else echo "не установлена"; fi)" \
        "Админка Element Admin" "$(if [ "$ELEMENT_ADMIN_ENABLED" = true ]; then echo "https://$DOMAIN_ADMIN_PANEL"; else echo "не установлена"; fi)" \
        "Логин админа" "$ADMIN_NICK" \
        "Пароль админа" "$pass_shown" \
        "Xray" "$(if [ "$NEED_XRAY" = yes ]; then echo /usr/local/etc/xray/config.json; else echo "не используется"; fi)" \
        "Мост Telegram" "$(bridge_summary_text)" \
        "Конфиг ansible" "$config" \
        "Параметры и секреты" "$ENV_FILE (не теряйте)"
    note "Применить ручные правки vars.yml: cd $REPO_DIR && sudo ansible-playbook -i inventory/hosts setup.yml --tags=setup-all,start"
    note "Панель управления: sudo matrix-up   Обновление: sudo matrix-up --update"
    note "Переустановка (matrix-up --install или пункт панели) пересоздаёт vars.yml из шаблона, прошлый файл: vars.yml.bak-ДАТА. --update его не трогает."
    [ "$UI" != gum ] || note "Журнал установки: $LOG_FILE"
    if [ "$ADMIN_REGISTERED" != yes ]; then
        warn "администратор $ADMIN_NICK не зарегистрирован. Если такой пользователь уже был, его пароль остался прежним. Другая частая причина: MAS счёл пароль слишком простым."
        note "Зарегистрировать вручную: cd $REPO_DIR && sudo ansible-playbook -i inventory/hosts setup.yml --extra-vars='username=ЛОГИН password=ПАРОЛЬ admin=yes' --tags=register-user"
    fi
}

# ---------- мост Telegram (telegram-bridge-advanced) ----------
#
# Два варианта:
#   local  - на этом сервере, встроенной ролью плейбука с образом форка;
#   remote - на отдельном сервере, ролью telegram-bridge-advanced-ansible (папка telegram-advanced в каталоге
#            плейбука, группа [telegram_bridge_servers] в inventory/hosts). Мост сам подключается к этому
#            серверу через wsproxy; скрипт заходит на тот сервер по SSH ключом BRIDGE_SSH_KEY.
# Настройки моста пишутся в vars.yml отдельным блоком между BRIDGE_BLOCK_BEGIN и BRIDGE_BLOCK_END,
# поэтому установка и удаление работают и с vars.yml, созданным прошлыми версиями скрипта.

# ask_bridge_mode -> 0 / 2 (назад). Значение: none | local | remote
ask_bridge_mode() {
    local value rc=0 choice header labels=() i def_label
    value="$(env_get TG_BRIDGE)"
    if [ -n "$value" ] && [ -z "${ASKED_FIELDS[TG_BRIDGE]:-}" ]; then
        TG_BRIDGE="$value"
        return 0
    fi
    # Ответы не с клавиатуры: вопрос не задаётся, чтобы не сдвинуть ответы
    if [ ! -t 0 ] && [ -z "$value" ]; then
        TG_BRIDGE=none
        env_set TG_BRIDGE none
        return 0
    fi
    ASKED_FIELDS[TG_BRIDGE]=1
    header="Установить мост Telegram (telegram-bridge-advanced)?"
    if [ "$NEED_XRAY" = yes ]; then
        header+=$'\n  На этом сервере — мост ходит в Telegram через Xray.'
    else
        header+=$'\n  На этом сервере — Telegram должен открываться с этого сервера.'
    fi
    header+=$'\n  На отдельном сервере — зарубежный VPS, нужен вход на него по SSH под root.'
    for i in none local remote; do labels+=("$(bridge_mode_label "$i")"); done
    def_label="$(bridge_mode_label "${value:-none}")"
    if [ "$UI" = gum ]; then
        choice="$("$GUM" choose --header "$header" --selected "$def_label" -- "${labels[@]}" "← Назад")" || rc=$?
        case "$rc" in
            0) ;;
            1)
                clear_gum_line
                return "$BACK"
                ;;
            *) cancel_input ;;
        esac
        [ "$choice" != "← Назад" ] || return "$BACK"
    else
        printf '%s\n' "$header" >&9
        for i in "${!labels[@]}"; do printf '  %d. %s\n' "$((i + 1))" "${labels[$i]}" >&9; done
        while true; do
            read -r -p "Номер [$def_label, < — назад]: " choice || die "ввод закончился, а ответы ещё нужны"
            [ "$choice" != "<" ] || return "$BACK"
            if [ -z "$choice" ]; then
                choice="$def_label"
                break
            fi
            if [[ "$choice" =~ ^[1-3]$ ]]; then
                choice="${labels[$((choice - 1))]}"
                break
            fi
            ui_invalid "Нет такого пункта."
        done
    fi
    for i in none local remote; do
        [ "$(bridge_mode_label "$i")" != "$choice" ] || TG_BRIDGE="$i"
    done
    env_set TG_BRIDGE "$TG_BRIDGE"
    ui_answer "Мост Telegram" "$choice"
}

bridge_mode_label() {
    case "$1" in
        local) echo "На этом сервере" ;;
        remote) echo "На отдельном сервере" ;;
        *) echo "Не ставить" ;;
    esac
}

is_api_id() { [[ "$1" =~ ^[1-9][0-9]{2,11}$ ]]; }
is_api_hash() { [[ "$1" =~ ^[0-9a-f]{32}$ ]]; }
is_port() { [[ "$1" =~ ^[0-9]{1,5}$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]; }
is_matrix_id() { [[ "$1" =~ ^@[a-z0-9._=/+-]+:[a-z0-9.-]+(:[0-9]+)?$ ]]; }
# Сервер моста - не этот же сервер
is_bridge_host() {
    [ "$1" != "${YOUR_IP:-}" ] || return 1
    is_ipv4 "$1" || is_domain "$1"
}
normalize_token() {
    local v="${1,,}"
    printf '%s' "${v//[[:space:]]/}"
}

# Что уже стоит: BRIDGE_KIND none | local | remote | manual, BRIDGE_FLAVOR advanced | original, BRIDGE_HOST.
# manual - wsproxy на этом сервере есть, а мост на отдельном сервере ставился не скриптом и не ролью.
BRIDGE_KIND=none
BRIDGE_FLAVOR=""
BRIDGE_HOST=""
bridge_detect() {
    local cfg="$1" hosts image
    hosts="$(dirname "$(dirname "$(dirname "$cfg")")")/hosts"
    BRIDGE_KIND=none BRIDGE_FLAVOR="" BRIDGE_HOST=""
    if [ "$(yaml_value "$cfg" matrix_bridge_mautrix_telegram_enabled)" = true ]; then
        BRIDGE_KIND=local
        image="$(yaml_value "$cfg" matrix_bridge_mautrix_telegram_container_image) $(yaml_value "$cfg" matrix_bridge_mautrix_telegram_container_image_self_build_repo)"
        if [[ "$image" == *telegram-bridge-advanced* ]]; then BRIDGE_FLAVOR=advanced; else BRIDGE_FLAVOR=original; fi
    elif [ -f "$hosts" ] && grep -qE '^\[telegram_bridge_servers\][[:space:]]*$' "$hosts"; then
        BRIDGE_KIND=remote BRIDGE_FLAVOR=advanced
        BRIDGE_HOST="$(bridge_inventory_value "$hosts" ansible_host)"
    elif [ -d "$BRIDGE_WSPROXY_DIR" ]; then
        BRIDGE_KIND=manual
    fi
}

# bridge_inventory_value hosts ключ - значение ключа у хоста группы [telegram_bridge_servers]
# (ansible_host без значения - имя хоста)
bridge_inventory_value() {
    awk -v key="$2" '
        /^\[/ { f = ($0 ~ /^\[telegram_bridge_servers\]/); next }
        f && NF && $1 !~ /^[#;]/ {
            for (i = 2; i <= NF; i++) if (index($i, key "=") == 1) { print substr($i, length(key) + 2); exit }
            if (key == "ansible_host") print $1
            exit
        }' "$1"
}

bridge_status_text() {
    case "$BRIDGE_KIND" in
        local)
            local state
            state="$(systemctl is-active matrix-mautrix-telegram 2> /dev/null || true)"
            if [ "$BRIDGE_FLAVOR" = advanced ]; then
                echo "на этом сервере, telegram-bridge-advanced (${state:-?})"
            else
                echo "на этом сервере, оригинальный mautrix-telegram (${state:-?})"
            fi
            ;;
        remote) echo "на отдельном сервере ${BRIDGE_HOST:-?}" ;;
        manual) echo "на отдельном сервере, установлен вручную" ;;
        *) echo "не установлен" ;;
    esac
}

bridge_ssh() {
    ssh -i "$BRIDGE_SSH_KEY" -p "$TG_SSH_PORT" -o BatchMode=yes -o ConnectTimeout=15 \
        -o StrictHostKeyChecking=accept-new "root@$TG_HOST" "$@"
}

# Доступ на сервер моста по SSH. Интерактивно, до шагов со спиннером.
# 0 - доступ есть, 1 - пользователь отказался.
ensure_bridge_ssh() {
    local choice rc
    if [ ! -f "$BRIDGE_SSH_KEY" ]; then
        install -d -m 700 "$(dirname "$BRIDGE_SSH_KEY")"
        ssh-keygen -q -t ed25519 -N "" -C "matrix-up@$(hostname)" -f "$BRIDGE_SSH_KEY" \
            || die "не удалось создать SSH-ключ $BRIDGE_SSH_KEY"
    fi
    while ! bridge_ssh true < /dev/null > /dev/null 2>&1; do
        ui_section "Доступ к серверу моста $TG_HOST"
        note "Скрипт заходит на сервер моста по SSH под root этим ключом. Добавьте его на $TG_HOST"
        note "в /root/.ssh/authorized_keys, например командой на том сервере:"
        printf "\n  echo '%s' >> /root/.ssh/authorized_keys\n\n" "$(cat "$BRIDGE_SSH_KEY.pub")" >&9
        [ -t 0 ] || die "нет доступа по SSH к root@$TG_HOST (порт $TG_SSH_PORT). Добавьте ключ выше и запустите скрипт снова"
        rc=0
        choice="$(ui_menu "Как продолжить?" \
            "Проверить снова" \
            "Скопировать ключ, введя пароль root от $TG_HOST" \
            "Не ставить мост")" || rc=$?
        [ "$rc" -eq 0 ] || choice="Не ставить мост"
        case "$choice" in
            "Скопировать ключ"*)
                ssh-copy-id -i "$BRIDGE_SSH_KEY.pub" -p "$TG_SSH_PORT" -o StrictHostKeyChecking=accept-new \
                    "root@$TG_HOST" < /dev/tty > /dev/tty 2>&1 || ui_invalid "Скопировать ключ не удалось."
                ;;
            "Не ставить мост") return 1 ;;
        esac
    done
    ui_answer "SSH до сервера моста" "root@$TG_HOST, порт $TG_SSH_PORT"
}

# Свои комнаты каналов у каждого пользователя включаются только у нового моста: у работающего
# существующие комнаты каналов не переезжают, и рядом появились бы новые. Результат в TG_PERSONAL_CHANNELS.
TG_PERSONAL_CHANNELS=true
bridge_detect_personal() {
    local state
    if [ "$TG_BRIDGE" = local ]; then
        if [ -f /matrix/mautrix-telegram/config/config.yaml ]; then
            state=false
            grep -qE '^[[:space:]]*personal_channels:[[:space:]]*true' /matrix/mautrix-telegram/config/config.yaml && state=true
        else
            state=new
        fi
    else
        state="$(bridge_ssh "if [ -f $BRIDGE_REMOTE_DIR/data/config.yaml ]; then
            grep -qE '^[[:space:]]*personal_channels:[[:space:]]*true' $BRIDGE_REMOTE_DIR/data/config.yaml && echo true || echo false
            else echo new; fi" < /dev/null)" || die "не удалось проверить мост на $TG_HOST по SSH"
    fi
    case "$state" in
        new) TG_PERSONAL_CHANNELS=true ;;
        true) TG_PERSONAL_CHANNELS=true ;;
        *)
            TG_PERSONAL_CHANNELS=false
            note "Мост уже работал, поэтому комнаты каналов остаются общими (свои комнаты у каждого — только у нового моста)"
            ;;
    esac
}

# bridge_inventory hosts set|remove - группа [telegram_bridge_servers] в inventory/hosts
bridge_inventory() {
    python3 - "$1" "$2" "${TG_HOST:-}" "${TG_SSH_PORT:-22}" "$BRIDGE_SSH_KEY" <<'PY' || die "не удалось изменить $1"
import sys

path, mode, host, port, key = sys.argv[1:6]
with open(path, encoding="utf-8") as f:
    lines = f.read().splitlines()
out, skip = [], False
for line in lines:
    s = line.strip()
    if s.startswith("[") and s.endswith("]"):
        skip = s == "[telegram_bridge_servers]"
        if skip:
            continue
    if not skip:
        out.append(line)
while out and not out[-1].strip():
    out.pop()
if mode == "set":
    out += ["", "[telegram_bridge_servers]",
            f"telegram-bridge ansible_host={host} ansible_port={port} ansible_user=root ansible_ssh_private_key_file={key}"]
with open(path, "w", encoding="utf-8") as f:
    f.write("\n".join(out) + "\n")
PY
}

# bridge_write_vars vars.yml local|remote|none [synapse] - блок настроек моста в vars.yml.
# Ключ, уже заданный вне блока одной строкой, меняется на месте; многострочный - конфликт (остановка).
# none убирает блок. synapse - подключить регистрацию моста к Synapse (только когда файл уже есть).
bridge_write_vars() {
    local admin="${TG_ADMIN:-}"
    [ -n "$admin" ] || admin="@${ADMIN_NICK:-admin}:$DOMAIN"
    python3 - "$1" "$2" "${3:-}" "$ENV_FILE" "$BRIDGE_IMAGE" "${NEED_XRAY:-no}" "$TG_PERSONAL_CHANNELS" "$admin" \
        "$BRIDGE_BLOCK_BEGIN" "$BRIDGE_BLOCK_END" "$DOCKER_BRIDGE_IP" <<'PY' || die "не удалось записать настройки моста в $1"
import json
import re
import sys

(path, mode, synapse, env_path, image, need_xray, personal, admin,
 begin, end, docker_ip) = sys.argv[1:12]

env = {}
with open(env_path, encoding="utf-8") as f:
    for line in f:
        m = re.match(r'^([A-Z_][A-Z0-9_]*)="(.*)"$', line.rstrip("\n"))
        if m:
            env[m.group(1)] = m.group(2)

with open(path, encoding="utf-8") as f:
    lines = f.read().split("\n")
out, inside = [], False
for line in lines:
    if line.strip() == begin:
        inside = True
        continue
    if line.strip() == end:
        inside = False
        continue
    if not inside:
        out.append(line)
while out and not out[-1].strip():
    out.pop()

key_re = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*):(.*)$")
top = {}
for i, line in enumerate(out):
    m = key_re.match(line)
    if m:
        top[m.group(1)] = i


def section(key):
    """Text of a top-level key with its indented continuation."""
    i = top[key]
    j = i + 1
    while j < len(out) and (not out[j].strip() or out[j][0] in " \t#-"):
        j += 1
    return "\n".join(out[i:j])


q = json.dumps
yes = lambda v: "true" if v in ("true", "yes") else "false"
entries = []  # (key, single-line value or None, text)


def scalar(key, value):
    entries.append((key, value, f"{key}: {value}"))


def multi(key, text):
    entries.append((key, None, text))


skip_outside = {"matrix_admin"}
enc = env.get("TG_ENCRYPTION") == "true"
if mode == "local":
    ext = [
        "bridge:",
        "  tag_only_on_create: false",
        "  mute_only_on_create: false",
        "network:",
        "  folder_spaces:",
        "    enabled: true",
        "    default_language: ru",
        "  matrix_request_timeout: 3h",
        "  backfill_split_media_mb: 10",
        "  extev_polls: true",
        "  sync:",
        "    update_limit: -1",
        "    create_limit: -1",
        "  max_member_count: 1000",
        f"  personal_channels: {yes(personal)}",
        "  max_initial_messages_override: {user: 300, saved: 1000}",
        "  comment_poll: {on_read_seconds: 60, background_minutes: 15, background_hours: 24}",
    ]
    if need_xray == "yes":
        ext += ["  proxy:", "    type: socks5", f'    address: "{docker_ip}:10808"']
    ext += ["backfill:", "  enabled: true", "  max_initial_messages: 30"]
    if enc:
        ext += ["encryption:", "  personal: true"]
    scalar("matrix_bridge_mautrix_telegram_enabled", "true")
    scalar("matrix_bridge_mautrix_telegram_api_id", env["TG_API_ID"])
    scalar("matrix_bridge_mautrix_telegram_api_hash", q(env["TG_API_HASH"]))
    scalar("matrix_bridge_mautrix_telegram_container_image", q(image))
    scalar("matrix_bridge_mautrix_telegram_bridge_personal_filtering_spaces", "false")
    scalar("matrix_appservice_double_puppet_enabled", "true")
    scalar("matrix_admin", q(admin))
    if enc:
        scalar("matrix_bridges_encryption_enabled", "true")
    multi("matrix_bridge_mautrix_telegram_configuration_extension_yaml",
          "matrix_bridge_mautrix_telegram_configuration_extension_yaml: |\n" + "\n".join("  " + l for l in ext))
elif mode == "remote":
    scalar("telegram_api_id", env["TG_API_ID"])
    scalar("telegram_api_hash", q(env["TG_API_HASH"]))
    scalar("telegram_bridge_language", "ru")
    scalar("telegram_bridge_encryption_enabled", yes(env.get("TG_ENCRYPTION", "false")))
    scalar("telegram_bridge_personal_channels", yes(personal))
    direct = env.get("TG_DIRECT_MEDIA") == "true"
    scalar("telegram_direct_media_enabled", yes(env.get("TG_DIRECT_MEDIA", "false")))
    if direct:
        scalar("telegram_media_hostname", q(env["TG_MEDIA_DOMAIN"]))
    scalar("matrix_appservice_double_puppet_enabled", "true")
    scalar("matrix_admin", q(admin))
    if synapse:
        wired = "matrix_synapse_app_service_config_files" in top and \
            "/matrix-telegram-registration.yaml" in section("matrix_synapse_app_service_config_files")
        if not wired:
            multi("matrix_synapse_container_additional_volumes",
                  "matrix_synapse_container_additional_volumes:\n"
                  "  - src: /opt/matrix-telegram-wsproxy/registration.yaml\n"
                  "    dst: /matrix-telegram-registration.yaml\n"
                  "    options: ro")
            multi("matrix_synapse_app_service_config_files",
                  "matrix_synapse_app_service_config_files:\n  - /matrix-telegram-registration.yaml")
        if enc:
            scalar("matrix_synapse_experimental_features_msc2409_to_device_messages_enabled", "true")
            scalar("matrix_synapse_experimental_features_msc3202_transaction_extensions_enabled", "true")

block, conflicts, changed = [], [], []
for key, value, text in entries:
    if key not in top:
        block.append(text)
        continue
    if key in skip_outside:
        continue
    current = key_re.match(out[top[key]]).group(2).split("#")[0].strip()
    if value is not None and current and current[0] not in "|>":
        out[top[key]] = text
        changed.append(key)
    else:
        conflicts.append(key)
if conflicts:
    sys.exit("в vars.yml уже есть многострочные настройки, которые скрипт не может объединить сам: "
             + ", ".join(conflicts) + ". Уберите их из vars.yml и повторите (нужное из них потом можно вернуть"
             + " ниже блока моста, объединив со значением из блока)")

text = "\n".join(out) + "\n"
if block:
    text += ("\n" + begin + "\n"
             + "# Блок пишет matrix-up (мост Telegram). Правки внутри перезапишутся при переустановке моста.\n"
             + "\n".join(block) + "\n" + end + "\n")
with open(path, "w", encoding="utf-8") as f:
    f.write(text)
for key in changed:
    print(f"изменено вне блока: {key}")
PY
}

# Отключение моста в vars.yml: убирает блок, у встроенной роли выключает мост, а регистрацию
# отдельного моста убирает из списков Synapse (в том числе вписанную вручную).
bridge_unwire_vars() {
    python3 - "$1" "$BRIDGE_BLOCK_BEGIN" "$BRIDGE_BLOCK_END" <<'PY' || die "не удалось изменить $1"
import re
import sys

path, begin, end = sys.argv[1:4]
with open(path, encoding="utf-8") as f:
    lines = f.read().split("\n")
out, inside = [], False
for line in lines:
    if line.strip() == begin:
        inside = True
        continue
    if line.strip() == end:
        inside = False
        continue
    if not inside:
        out.append(line)

key_re = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*):(.*)$")
markers = ("matrix-telegram-registration", "/opt/matrix-telegram-wsproxy/registration.yaml")
lists = {"matrix_synapse_container_extra_arguments", "matrix_synapse_container_additional_volumes",
         "matrix_synapse_app_service_config_files"}
result, i = [], 0
while i < len(out):
    line = out[i]
    m = key_re.match(line)
    if m and m.group(1) == "matrix_bridge_mautrix_telegram_enabled":
        result.append("matrix_bridge_mautrix_telegram_enabled: false")
        i += 1
        continue
    if not (m and m.group(1) in lists and not m.group(2).split("#")[0].strip()):
        result.append(line)
        i += 1
        continue
    # Список: элементы начинаются с "- ", продолжение элемента - строки с большим отступом
    j = i + 1
    body = []
    while j < len(out) and (not out[j].strip() or out[j][0] in " \t#-"):
        body.append(out[j])
        j += 1
    items, current, kept_lines = [], None, []
    for b in body:
        stripped = b.lstrip()
        if stripped.startswith("- "):
            current = [b]
            items.append(current)
        elif current is not None and b.strip() and not stripped.startswith("#") \
                and len(b) - len(stripped) > len(current[0]) - len(current[0].lstrip()):
            current.append(b)
        else:
            current = None
            items.append([b])
    kept = [it for it in items if not (it[0].lstrip().startswith("- ") and any(mk in "\n".join(it) for mk in markers))]
    removed = len(kept) != len(items)
    if removed and not any(it[0].lstrip().startswith("- ") for it in kept):
        # Список опустел: ключ убирается целиком (пустой ключ - это null, а не пустой список)
        result.extend(l for it in kept for l in it if not l.strip() or l.lstrip().startswith("#"))
    else:
        result.append(line)
        result.extend(l for it in kept for l in it)
    i = j
while result and not result[-1].strip():
    result.pop()
with open(path, "w", encoding="utf-8") as f:
    f.write("\n".join(result) + "\n")
PY
}

# Строки vars.yml, которые всё ещё подключают регистрацию отдельного моста к Synapse
bridge_synapse_wired() {
    grep -nE 'matrix-telegram-registration|/opt/matrix-telegram-wsproxy/registration\.yaml' "$1"
}

# Роль telegram-bridge-advanced-ansible в $REPO_DIR/telegram-advanced, версия BRIDGE_ROLE_TAG.
# Более новую версию, уже лежащую там, не откатывает.
bridge_fetch_role() {
    local dir="$REPO_DIR/$BRIDGE_ROLE_DIR"
    if [ ! -d "$dir/.git" ]; then
        [ ! -e "$dir" ] || die "$dir существует, но это не git-репозиторий. Переименуйте его и запустите скрипт снова"
        run_with_retry "rm -rf '$dir.partial' && git clone -q '$BRIDGE_ROLE_REPO' '$dir.partial'" 5
        mv "$dir.partial" "$dir"
    else
        run_with_retry "git -C '$dir' fetch -q --tags origin" 5
    fi
    if git -C "$dir" merge-base --is-ancestor "$BRIDGE_ROLE_TAG" HEAD 2> /dev/null \
        && [ "$(git -C "$dir" rev-parse HEAD)" != "$(git -C "$dir" rev-parse "$BRIDGE_ROLE_TAG^{commit}")" ]; then
        note "Роль моста новее $BRIDGE_ROLE_TAG, оставлена как есть"
    else
        git -C "$dir" checkout -q "$BRIDGE_ROLE_TAG" \
            || die "не удалось переключить $dir на $BRIDGE_ROLE_TAG: там есть локальные изменения"
        note "Роль моста: $BRIDGE_ROLE_TAG"
    fi
}

bridge_run_site() {
    run_with_retry "ansible-playbook -i inventory/hosts $BRIDGE_ROLE_DIR/site.yml" 3 \
        || die "установка моста не удалась. Повторить вручную: cd $REPO_DIR && sudo ansible-playbook -i inventory/hosts $BRIDGE_ROLE_DIR/site.yml"
}

bridge_run_synapse() {
    run_with_retry "ansible-playbook -i inventory/hosts setup.yml --tags=setup-synapse,start" 3 \
        || die "не удалось применить настройки Synapse. Повторить вручную: cd $REPO_DIR && sudo ansible-playbook -i inventory/hosts setup.yml --tags=setup-synapse,start"
}

# Подключает регистрацию отдельного моста к Synapse, если она ещё не подключена
bridge_connect_synapse() {
    local file="$1"
    [ -s "$BRIDGE_REGISTRATION" ] || die "мост не создал регистрацию $BRIDGE_REGISTRATION"
    bridge_write_vars "$file" remote synapse
    bridge_run_synapse
}

bridge_verify() {
    if ansible-playbook -i inventory/hosts "$BRIDGE_ROLE_DIR/verify.yml"; then
        note "Мост и wsproxy работают"
    else
        warn "проверка моста нашла остановленные контейнеры, подробности в журнале"
    fi
}

# Двойной вход (matrix-appservice-double-puppet) нужен до установки отдельного моста
bridge_double_puppet() {
    if [ -s /matrix/appservice-double-puppet/config/registration.yaml ]; then
        note "Двойной вход уже включён"
        return 0
    fi
    apply_install_all
}

apply_install_all() {
    run_with_retry "ansible-playbook -i inventory/hosts setup.yml --tags=install-all,start" 3 \
        || die "плейбук завершился с ошибкой. Прошлый vars.yml сохранён рядом как vars.yml.bak-ДАТА.
Повторить вручную: cd $REPO_DIR && sudo ansible-playbook -i inventory/hosts setup.yml --tags=install-all,start"
}

bridge_summary_text() {
    case "$TG_BRIDGE" in
        local) echo "на этом сервере: напишите «login qr» боту @telegrambot:$DOMAIN" ;;
        remote) echo "на $TG_HOST: напишите «login qr» боту @telegrambot:$DOMAIN" ;;
        *) echo "не установлен" ;;
    esac
}

# Значения для вопросов о мосте в панели: из файла параметров, иначе из vars.yml
bridge_panel_context() {
    local cfg="$1" hosts
    hosts="$REPO_DIR/inventory/hosts"
    DOMAIN="$(yaml_value "$cfg" matrix_domain)"
    DOMAIN_MATRIX="$(yaml_value "$cfg" matrix_server_fqn_matrix)"
    YOUR_IP="$(yaml_value "$cfg" your_ip)"
    NEED_XRAY=no
    grep -qE '^your_proxy_http_proxy:[[:space:]]*[^[:space:]]' "$cfg" && NEED_XRAY=yes
    local key value
    for key in TG_API_ID:matrix_bridge_mautrix_telegram_api_id TG_API_HASH:matrix_bridge_mautrix_telegram_api_hash \
        TG_API_ID:telegram_api_id TG_API_HASH:telegram_api_hash; do
        value="$(yaml_value "$cfg" "${key#*:}")"
        if [ -n "$value" ] && [[ "$value" != *"{{"* ]] && [ -z "$(env_get "${key%%:*}")" ]; then
            env_set "${key%%:*}" "$value"
        fi
    done
    if [ -z "$(env_get TG_ADMIN)" ]; then
        value="$(yaml_value "$cfg" matrix_admin)"
        is_matrix_id "$value" || value="@admin:$DOMAIN"
        TG_ADMIN_DEFAULT="$value"
    fi
    if [ -f "$hosts" ] && [ -z "$(env_get TG_HOST)" ]; then
        value="$(bridge_inventory_value "$hosts" ansible_host)"
        [ -z "$value" ] || env_set TG_HOST "$value"
    fi
}

# Пункт панели: установить мост (new), подключить установленный вручную (adopt),
# перевести оригинальный mautrix-telegram на форк (upgrade)
panel_bridge_install() {
    local how="$1" rc=0 saved_questions=("${QUESTIONS[@]}")
    find_single_config
    REPO_DIR="$(find_repo_dir)"
    prepare_env_file
    bridge_panel_context "$PANEL_CONFIG"
    BRIDGE_ONLY=yes
    ASKED_FIELDS=()
    case "$how" in
        new) ASKED_FIELDS[TG_BRIDGE]=1 ;;
        adopt) env_set TG_BRIDGE remote ;;
        upgrade) env_set TG_BRIDGE local ;;
    esac
    QUESTIONS=(TG_BRIDGE TG_API_ID TG_API_HASH TG_HOST TG_SSH_PORT TG_ENCRYPTION TG_DIRECT_MEDIA TG_MEDIA_DOMAIN TG_ADMIN)
    ui_clear
    case "$how" in
        new) ui_banner "Matrix · мост Telegram" "telegram-bridge-advanced: папки, комментарии, опросы и другое" ;;
        adopt) ui_banner "Matrix · мост Telegram" "подключение моста, установленного вручную: его база и вход в Telegram сохранятся" ;;
        upgrade) ui_banner "Matrix · мост Telegram" "переход с mautrix-telegram на telegram-bridge-advanced: база и вход в Telegram сохранятся" ;;
    esac
    run_questions 0
    if [ "$TG_BRIDGE" = none ]; then
        QUESTIONS=("${saved_questions[@]}")
        return 0
    fi
    while true; do
        rc=0
        review_answers "Начать" || rc=$?
        [ "$rc" -eq "$BACK" ] || break
        run_questions "$((${#QUESTIONS[@]} - 1))"
    done
    QUESTIONS=("${saved_questions[@]}")
    TG_ADMIN="$(env_get TG_ADMIN)"
    if [ "$TG_BRIDGE" = remote ] && ! ensure_bridge_ssh; then
        PANEL_MSG="Мост не установлен: нет доступа к серверу моста по SSH"
        return 0
    fi

    cd "$REPO_DIR" || die "директория $REPO_DIR недоступна"
    load_proxy_env
    BRIDGE_VARS_FILE="$PANEL_CONFIG"
    STEP_NO=0
    if [ "$TG_BRIDGE" = local ]; then
        STEP_TOTAL=2
        run_step "Настройки моста в vars.yml" bridge_prepare_vars
        STEP_HINT="10–20 минут, подробности: tail -f $LOG_FILE"
        run_step "Установка моста (плейбук)" apply_install_all
        STEP_HINT=""
    else
        STEP_TOTAL=6
        run_step "Роль моста" bridge_fetch_role
        run_step "Настройки моста в vars.yml и inventory" bridge_prepare_vars
        STEP_HINT="10–20 минут, подробности: tail -f $LOG_FILE"
        run_step "Двойной вход" bridge_double_puppet
        run_step "Установка моста на $TG_HOST" bridge_run_site
        run_step "Подключение моста к Synapse" bridge_connect_synapse "$PANEL_CONFIG"
        STEP_HINT=""
        run_step "Проверка" bridge_verify
    fi
    PANEL_MSG="Мост Telegram установлен: $(bridge_summary_text)"
}

# Шаг: копия vars.yml, проверка существующего моста, блок настроек, inventory
BRIDGE_VARS_FILE=""
bridge_prepare_vars() {
    local backup
    if [ "$MODE" != install ]; then
        backup="$BRIDGE_VARS_FILE.bak-$(date +%Y%m%d-%H%M%S)"
        cp -p "$BRIDGE_VARS_FILE" "$backup"
        note "Прошлый vars.yml сохранён: $backup"
    fi
    bridge_detect_personal
    if [ "$TG_BRIDGE" = remote ]; then
        bridge_inventory "$REPO_DIR/inventory/hosts" set
        # Регистрация уже есть (переустановка или ручная установка) - Synapse подключается сразу
        if [ -s "$BRIDGE_REGISTRATION" ]; then
            bridge_write_vars "$BRIDGE_VARS_FILE" remote synapse
        else
            bridge_write_vars "$BRIDGE_VARS_FILE" remote
        fi
    else
        bridge_write_vars "$BRIDGE_VARS_FILE" local
    fi
}

# Пункт панели: удалить мост (любой из найденных bridge_detect)
panel_bridge_remove() {
    local rc=0 keep=yes text wired
    find_single_config
    REPO_DIR="$(find_repo_dir)"
    bridge_detect "$PANEL_CONFIG"
    case "$BRIDGE_KIND" in
        local) text="Удалить мост Telegram с этого сервера? Комнаты в Matrix останутся, данные моста (/matrix/mautrix-telegram, база в Postgres) — тоже, их можно удалить следующим вопросом." ;;
        remote) text="Удалить мост Telegram с ${BRIDGE_HOST:-сервера моста} и wsproxy с этого сервера? Комнаты в Matrix останутся." ;;
        manual) text="Отключить мост Telegram, установленный вручную: убрать его регистрацию из Synapse и wsproxy с этого сервера? Сам мост на его сервере остановите вручную (docker compose down в его каталоге). Комнаты в Matrix останутся." ;;
        *)
            PANEL_MSG="Мост Telegram не найден"
            return 0
            ;;
    esac
    ui_yes_no "$text" no || rc=$?
    [ "$rc" -eq 0 ] || return 0
    if [ "$BRIDGE_KIND" = remote ]; then
        rc=0
        ui_yes_no "Оставить на ${BRIDGE_HOST:-сервере моста} базу моста ($BRIDGE_REMOTE_DIR: вход в Telegram, связи комнат)? Без неё повторная установка начнёт заново." yes || rc=$?
        case "$rc" in
            0) keep=yes ;;
            1) keep=no ;;
            *) return 0 ;;
        esac
    fi

    cd "$REPO_DIR" || die "директория $REPO_DIR недоступна"
    load_proxy_env
    prepare_env_file
    ui_clear
    ui_banner "Matrix · удаление моста Telegram" "$(bridge_status_text)"
    STEP_NO=0
    cp -p "$PANEL_CONFIG" "$PANEL_CONFIG.bak-$(date +%Y%m%d-%H%M%S)"
    bridge_unwire_vars "$PANEL_CONFIG"
    if wired="$(bridge_synapse_wired "$PANEL_CONFIG")"; then
        die "регистрацию моста не удалось убрать из $PANEL_CONFIG автоматически, строки:
$wired
Уберите их вручную и повторите удаление (прошлый vars.yml сохранён рядом как vars.yml.bak-ДАТА)"
    fi
    STEP_HINT="10–20 минут, подробности: tail -f $LOG_FILE"
    if [ "$BRIDGE_KIND" = local ]; then
        STEP_TOTAL=1
        run_step "Удаление моста (плейбук)" apply_setup_all
        STEP_HINT=""
        rc=0
        ui_yes_no "Удалить и данные моста (/matrix/mautrix-telegram)? Вход в Telegram и связи комнат пропадут, повторная установка начнёт заново." no || rc=$?
        if [ "$rc" -eq 0 ]; then
            rm -rf /matrix/mautrix-telegram
            note "Данные моста удалены. База matrix_mautrix_telegram в Postgres осталась, она не мешает."
        fi
    else
        STEP_TOTAL=3
        run_step "Отключение моста от Synapse" bridge_run_synapse
        STEP_HINT=""
        run_step "Роль моста" bridge_fetch_role
        run_step "Удаление моста и wsproxy" bridge_run_uninstall "$keep"
        bridge_inventory "$REPO_DIR/inventory/hosts" remove
        rm -rf "${REPO_DIR:?}/$BRIDGE_ROLE_DIR"
    fi
    env_set TG_BRIDGE none
    PANEL_MSG="Мост Telegram удалён. Двойной вход (matrix_appservice_double_puppet_enabled) оставлен включённым."
    [ "$keep" = no ] || [ "$BRIDGE_KIND" != remote ] || PANEL_MSG+=" База моста осталась на ${BRIDGE_HOST:-его сервере} в $BRIDGE_REMOTE_DIR."
}

bridge_run_uninstall() {
    local keep=true
    [ "$1" = yes ] || keep=false
    run_with_retry "ansible-playbook -i inventory/hosts $BRIDGE_ROLE_DIR/uninstall.yml -e telegram_uninstall_keep_data=$keep" 3 \
        || die "удаление не завершилось. Повторить вручную: cd $REPO_DIR && sudo ansible-playbook -i inventory/hosts $BRIDGE_ROLE_DIR/uninstall.yml"
}

# Обновление: отдельный мост обновляется вместе с Matrix (роль и образ своей версии)
bridge_update_steps() {
    run_step "Роль моста" bridge_fetch_role
    run_step "Обновление моста на ${BRIDGE_HOST:-сервере моста}" bridge_run_site
}

# ---------- системная команда и параметры ----------

# Копирует скрипт в INSTALL_DIR и создаёт команды matrix-up и matrix_up.
# Более новую уже установленную версию не заменяет.
install_self() {
    local installed_tag="" name link
    if [ "$SCRIPT_PATH" != "$INSTALLED_SCRIPT" ] && [ -f "$SCRIPT_PATH" ]; then
        if [ -f "$INSTALLED_SCRIPT" ]; then
            installed_tag="$(sed -n 's/^RELEASE_TAG="\(.*\)"$/\1/p' "$INSTALLED_SCRIPT" | head -1)"
        fi
        if [ -n "$installed_tag" ] && [ "$(printf '%s\n%s\n' "$installed_tag" "$RELEASE_TAG" | sort -V | tail -1)" != "$RELEASE_TAG" ]; then
            note "Команда matrix-up оставлена на более новой версии $installed_tag"
        elif install -D -m 755 "$SCRIPT_PATH" "$INSTALLED_SCRIPT.new" 2> /dev/null && mv -f "$INSTALLED_SCRIPT.new" "$INSTALLED_SCRIPT"; then
            [ "$installed_tag" = "$RELEASE_TAG" ] || note "Скрипт установлен в систему: команда matrix-up (или matrix_up)"
        else
            rm -f "$INSTALLED_SCRIPT.new"
            warn "не удалось установить скрипт в $INSTALL_DIR, команда matrix-up недоступна"
            return 0
        fi
    fi
    [ -f "$INSTALLED_SCRIPT" ] || return 0
    for name in "${COMMAND_NAMES[@]}"; do
        link="$BIN_DIR/$name"
        # Чужой файл с таким именем не трогаем
        if [ -e "$link" ] && [ "$(readlink -f "$link")" != "$INSTALLED_SCRIPT" ]; then
            warn "$link уже существует и это не наш скрипт, команда $name не создана"
            continue
        fi
        ln -sfn "$INSTALLED_SCRIPT" "$link" 2> /dev/null || warn "не удалось создать команду $link"
    done
}

# Файл параметров в CONFIG_DIR. Параметры прошлых версий (.env рядом со скриптом) переносятся.
prepare_env_file() {
    install -d -m 700 "$CONFIG_DIR" || die "не удалось создать $CONFIG_DIR"
    if [ ! -s "$ENV_FILE" ] && [ -s "$OLD_ENV_FILE" ]; then
        cp "$OLD_ENV_FILE" "$ENV_FILE" || die "не удалось перенести $OLD_ENV_FILE в $ENV_FILE"
        note "Параметры перенесены из $OLD_ENV_FILE в $ENV_FILE (старый файл больше не используется)"
    fi
    touch "$ENV_FILE" || die "не удалось создать $ENV_FILE"
    chmod 600 "$ENV_FILE"
}

# Есть ли уже установленный Matrix (конфиг плейбука)
has_installation() {
    compgen -G "$(find_repo_dir)/inventory/host_vars/*/vars.yml" > /dev/null
}

# ---------- панель управления (пункты будут расширяться) ----------

# ui_menu "заголовок" пункт... -> печатает выбранный пункт; код 2 - Esc/назад
ui_menu() {
    local header="$1" choice rc=0 i
    shift
    if [ "$UI" = gum ]; then
        choice="$("$GUM" choose --header "$header" -- "$@")" || rc=$?
        case "$rc" in
            0) printf '%s' "$choice" ;;
            1)
                clear_gum_line
                return "$BACK"
                ;;
            *) cancel_input ;;
        esac
        return 0
    fi
    printf '\n%s\n' "$header" >&9
    for ((i = 1; i <= $#; i++)); do
        printf '  %d. %s\n' "$i" "${!i}" >&9
    done
    while true; do
        read -r -p "Номер пункта: " choice || die "ввод закончился"
        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le $# ]; then
            printf '%s' "${!choice}"
            return 0
        fi
        ui_invalid "Нет такого пункта."
    done
}

panel_status() {
    local units active failed failed_list xray docker_state disk repo
    units="$(systemctl list-units 'matrix-*' --all --no-legend --plain 2> /dev/null || true)"
    active="$(awk '$3 == "active"' <<< "$units" | grep -c . || true)"
    failed="$(awk '$3 == "failed"' <<< "$units" | grep -c . || true)"
    failed_list="$(awk '$3 == "failed" {print $1}' <<< "$units" | paste -sd, - || true)"
    if command -v xray > /dev/null 2>&1 || [ -x /usr/local/bin/xray ]; then
        xray="$(systemctl is-active xray 2> /dev/null || true)"
    else
        xray="не установлен"
    fi
    docker_state="$(systemctl is-active docker 2> /dev/null || true)"
    disk="$(df -h / | awk 'NR == 2 {print $3 " из " $2 " (" $5 ")"}')"
    repo="$(find_repo_dir)"
    find_single_config
    bridge_detect "$PANEL_CONFIG"
    local ketesa element_admin fqn
    fqn="$(yaml_value "$PANEL_CONFIG" matrix_server_fqn_matrix)"
    if [ "$(yaml_value "$PANEL_CONFIG" matrix_ketesa_enabled)" = true ]; then
        ketesa="https://$fqn/synapse-admin/"
    else
        ketesa="не установлена"
    fi
    if [ "$(yaml_value "$PANEL_CONFIG" matrix_element_admin_enabled)" = true ]; then
        element_admin="https://$(yaml_value "$PANEL_CONFIG" matrix_element_admin_hostname)"
    else
        element_admin="не установлена"
    fi
    ui_section "Состояние"
    ui_table \
        "Сервисы Matrix" "работают: $active, с ошибкой: $failed" \
        "С ошибкой" "${failed_list:-нет}" \
        "Docker" "${docker_state:-неизвестно}" \
        "Xray" "${xray:-неизвестно}" \
        "Ketesa" "$ketesa" \
        "Element Admin" "$element_admin" \
        "Мост Telegram" "$(bridge_status_text)" \
        "Диск /" "$disk" \
        "Плейбук" "$repo ($(git -C "$repo" rev-parse --short HEAD 2> /dev/null || echo "?"))" \
        "Скрипт" "$RELEASE_TAG"
}

panel_log() {
    local log="/var/log/matrix_up.log"
    if [ ! -s "$log" ]; then
        PANEL_MSG="Журнала установки ещё нет ($log)"
        return 0
    fi
    if [ "$UI" = gum ]; then
        "$GUM" pager < "$log" || true
    else
        tail -n 40 "$log"
        read -r -p "Enter — назад в панель " _ || true
    fi
}

# Запуск другого режима этого же скрипта (рабочая папка текущего процесса больше не нужна)
panel_exec() {
    ui_clear
    rm -rf "$WORK_DIR"
    WORK_DIR=""
    exec bash "$SCRIPT_PATH" "$@"
}

PANEL_MSG=""

# Единственный конфиг установленного плейбука (результат в PANEL_CONFIG)
PANEL_CONFIG=""
find_single_config() {
    local repo f configs=()
    repo="$(find_repo_dir)"
    for f in "$repo"/inventory/host_vars/*/vars.yml; do
        [ -f "$f" ] && configs+=("$f")
    done
    [ "${#configs[@]}" -gt 0 ] || die "установка не найдена (нет $repo/inventory/host_vars/*/vars.yml)"
    [ "${#configs[@]}" -eq 1 ] || die "в $repo/inventory/host_vars несколько конфигов, правьте вручную: ${configs[*]}"
    PANEL_CONFIG="${configs[0]}"
}

# yaml_value файл ключ - значение верхнеуровневого ключа без кавычек (пусто, если ключа нет)
yaml_value() {
    sed -n "s/^$2:[[:space:]]*//p" "$1" | tail -1 | sed -E "s/[[:space:]]+#.*$//; s/^[\"']//; s/[\"']$//"
}

# yaml_set файл ключ значение - заменяет строку ключа или дописывает её в конец
yaml_set() {
    if grep -q "^$2:" "$1"; then
        sed -i "s|^$2:.*|$2: $3|" "$1"
    else
        printf '\n%s: %s\n' "$2" "$3" >> "$1"
    fi
}

# Плейбук целиком: setup-all удаляет выключенные сервисы (install-all их бы оставил)
apply_setup_all() {
    run_with_retry "ansible-playbook -i inventory/hosts setup.yml --tags=setup-all,start" 3 \
        || die "плейбук завершился с ошибкой. Прошлый vars.yml сохранён рядом как vars.yml.bak-ДАТА.
Повторить вручную: cd $REPO_DIR && sudo ansible-playbook -i inventory/hosts setup.yml --tags=setup-all,start"
}

# panel_toggle ketesa|element_admin - установить или удалить админку
panel_toggle() {
    local what="$1" key envkey label current new action process hostname="" rc=0
    case "$what" in
        ketesa) key=matrix_ketesa_enabled envkey=KETESA_ENABLED label="Ketesa" ;;
        element_admin) key=matrix_element_admin_enabled envkey=ELEMENT_ADMIN_ENABLED label="Element Admin" ;;
    esac
    find_single_config
    current="$(yaml_value "$PANEL_CONFIG" "$key")"
    if [ "$current" = true ]; then
        new=false action="Удалить" process="удаление"
    else
        new=true action="Установить" process="установка"
    fi

    if [ "$what" = element_admin ] && [ "$new" = true ]; then
        hostname="$(yaml_value "$PANEL_CONFIG" matrix_element_admin_hostname)"
        if [ -z "$hostname" ]; then
            hostname="$(prompt_value "Поддомен для Element Admin (нужна DNS-запись на этот сервер)" "admin.$(yaml_value "$PANEL_CONFIG" matrix_domain)")" || rc=$?
            [ "$rc" -ne "$BACK" ] || return 0
            [ "$rc" -eq 0 ] || exit "$rc"
            hostname="$(normalize_domain "$hostname")"
            if ! is_domain "$hostname"; then
                PANEL_MSG="Некорректный домен: $hostname"
                return 0
            fi
        fi
    fi
    rc=0
    ui_yes_no "$action админку $label? Плейбук применит изменения, это займёт 10–20 минут." yes || rc=$?
    [ "$rc" -eq 0 ] || return 0

    cp -p "$PANEL_CONFIG" "$PANEL_CONFIG.bak-$(date +%Y%m%d-%H%M%S)"
    yaml_set "$PANEL_CONFIG" "$key" "$new"
    [ -z "$hostname" ] || yaml_set "$PANEL_CONFIG" matrix_element_admin_hostname "\"$hostname\""
    # Запоминаем выбор для переустановки
    if [ -s "$ENV_FILE" ]; then
        env_set "$envkey" "$new"
        [ -z "$hostname" ] || env_set DOMAIN_ADMIN_PANEL "$hostname"
    fi

    REPO_DIR="$(find_repo_dir)"
    cd "$REPO_DIR" || die "директория $REPO_DIR недоступна"
    load_proxy_env
    ui_clear
    ui_banner "Matrix · $process админки $label" "изменён $PANEL_CONFIG (прошлый: vars.yml.bak-ДАТА)"
    STEP_NO=0
    STEP_TOTAL=1
    STEP_HINT="10–20 минут, подробности: tail -f $LOG_FILE"
    run_step "Применение настроек (setup-all)" apply_setup_all
    STEP_HINT=""
    if [ "$new" = true ]; then
        PANEL_MSG="Админка $label установлена"
    else
        PANEL_MSG="Админка $label удалена"
    fi
}

# Подпись пункта меню по текущему состоянию
admin_menu_label() {
    local key="$1" label="$2"
    if [ "$(yaml_value "$PANEL_CONFIG" "$key")" = true ]; then
        echo "Удалить админку $label"
    else
        echo "Установить админку $label"
    fi
}

# Панель перерисовывается целиком при каждом показе меню: заголовок, состояние, сообщение, меню
run_panel() {
    local choice rc server_name ketesa_item element_admin_item bridge_items
    server_name="$(sed -n 's/^matrix_server_fqn_matrix:[[:space:]]*"\{0,1\}\([^" #]*\).*/\1/p' "$(find_repo_dir)"/inventory/host_vars/*/vars.yml 2> /dev/null | head -1)"
    while true; do
        ui_clear
        ui_banner "Matrix · панель управления" "${server_name:-сервер Matrix} · версия скрипта: $RELEASE_TAG"
        panel_status
        if [ -n "$PANEL_MSG" ]; then
            note "$PANEL_MSG"
            PANEL_MSG=""
        fi
        rc=0
        ketesa_item="$(admin_menu_label matrix_ketesa_enabled "Ketesa")"
        element_admin_item="$(admin_menu_label matrix_element_admin_enabled "Element Admin")"
        # bridge_detect уже вызван в panel_status
        case "$BRIDGE_KIND" in
            none) bridge_items=("Установить мост Telegram") ;;
            manual) bridge_items=("Подключить мост Telegram к matrix-up" "Удалить мост Telegram") ;;
            local)
                if [ "$BRIDGE_FLAVOR" = original ]; then
                    bridge_items=("Перевести мост Telegram на telegram-bridge-advanced" "Удалить мост Telegram")
                else
                    bridge_items=("Удалить мост Telegram")
                fi
                ;;
            *) bridge_items=("Удалить мост Telegram") ;;
        esac
        choice="$(ui_menu "Что сделать?" \
            "Обновить состояние" \
            "Обновить Matrix" \
            "$ketesa_item" \
            "$element_admin_item" \
            "${bridge_items[@]}" \
            "Изменить параметры и переустановить" \
            "Журнал последней установки" \
            "Выход")" || rc=$?
        [ "$rc" -eq 0 ] || exit 0
        case "$choice" in
            "Обновить состояние") ;;
            *"админку Ketesa") panel_toggle ketesa ;;
            *"админку Element Admin") panel_toggle element_admin ;;
            "Обновить Matrix") panel_exec --update ;;
            "Установить мост Telegram") panel_bridge_install new ;;
            "Подключить мост Telegram к matrix-up") panel_bridge_install adopt ;;
            "Перевести мост Telegram на telegram-bridge-advanced") panel_bridge_install upgrade ;;
            "Удалить мост Telegram") panel_bridge_remove ;;
            "Изменить параметры и переустановить") panel_exec --install ;;
            "Журнал последней установки") panel_log ;;
            *) exit 0 ;;
        esac
    done
}

# ---------- режим --update ----------

# Прокси из /etc/environment (его пишет setup_proxy, если стоит Xray). Читаем как данные, без source.
load_proxy_env() {
    local line key value
    [ -f /etc/environment ] || return 0
    while IFS= read -r line; do
        [[ "$line" =~ ^(http_proxy|https_proxy|ftp_proxy|no_proxy|HTTP_PROXY|HTTPS_PROXY|FTP_PROXY|NO_PROXY)=(.*)$ ]] || continue
        key="${BASH_REMATCH[1]}"
        value="${BASH_REMATCH[2]}"
        value="${value#\"}"
        value="${value%\"}"
        export "$key=$value"
    done < /etc/environment
}

# Поднимает matrix_playbook_migration_validated_version в vars.yml до PLAYBOOK_VERSION.
# Больше в vars.yml ничего не меняется. Если там уже версия не старше, файл не трогается.
bump_validated_version() {
    local file="$1" current
    current="$(sed -n 's/^matrix_playbook_migration_validated_version:[[:space:]]*//p' "$file" | tr -d "\"' \r" | tail -1)"
    if [ -n "$current" ] && [ "$(printf '%s\n%s\n' "$current" "$PLAYBOOK_VERSION" | sort -V | tail -1)" = "$current" ]; then
        note "В vars.yml версия плейбука $current, менять не нужно"
        return
    fi
    cp -p "$file" "$file.bak-$(date +%Y%m%d-%H%M%S)"
    if [ -n "$current" ]; then
        sed -i "s/^matrix_playbook_migration_validated_version:.*/matrix_playbook_migration_validated_version: $PLAYBOOK_VERSION/" "$file"
    else
        printf '\nmatrix_playbook_migration_validated_version: %s\n' "$PLAYBOOK_VERSION" >> "$file"
    fi
    note "В vars.yml версия плейбука: ${current:-не задана} → $PLAYBOOK_VERSION (прошлый файл: vars.yml.bak-ДАТА)"
}

# Переход на последний релиз скрипта той же мажорной версии (только в режиме --update).
# Любая неудача не мешает обновлению: продолжаем с текущей версией скрипта.
self_update() {
    [ "$SELF_UPDATE" = yes ] || return 0
    echo "Проверяем, нет ли новой версии скрипта..."
    local latest
    latest="$(git ls-remote --tags --refs "$PROJECT_URL.git" 2> /dev/null \
        | sed -n 's#.*refs/tags/\(v[0-9]*\.[0-9]*\.[0-9]*\)$#\1#p' | sort -V | tail -1 || true)"
    if [ -z "$latest" ]; then
        warn "не удалось узнать последнюю версию скрипта, продолжаем с $RELEASE_TAG"
        return 0
    fi
    if [ "$(printf '%s\n%s\n' "$latest" "$RELEASE_TAG" | sort -V | tail -1)" = "$RELEASE_TAG" ]; then
        echo "Скрипт актуален ($RELEASE_TAG)"
        return 0
    fi
    if [ "${latest%%.*}" != "${RELEASE_TAG%%.*}" ]; then
        warn "вышла версия скрипта $latest с несовместимыми изменениями, автоматически на неё не переходим. Прочитайте описание: $PROJECT_URL/releases. Продолжаем с $RELEASE_TAG"
        return 0
    fi

    local self new
    self="$SCRIPT_PATH"
    new="$WORK_DIR/matrix_up.sh.new"
    if ! curl -fsSL "$RAW_ROOT/$latest/scripts/matrix_up.sh" -o "$new"; then
        warn "не удалось скачать скрипт $latest, продолжаем с $RELEASE_TAG"
        return 0
    fi
    # Запускаем только скрипт, который заявляет нужную версию и умеет --update без вопросов
    if ! bash -n "$new" || ! grep -qx "RELEASE_TAG=\"$latest\"" "$new" || ! grep -q -- '--no-self-update) SELF_UPDATE=no' "$new"; then
        warn "скачанный скрипт $latest не прошёл проверку, продолжаем с $RELEASE_TAG"
        return 0
    fi
    # Новый файл кладём рядом и переименовываем: работающий bash продолжает читать старый файл
    if ! { cp "$new" "$self.new" && chmod 755 "$self.new" && chown --reference="$self" "$self.new" && mv -f "$self.new" "$self"; } 2> /dev/null; then
        rm -f "$self.new"
        warn "не удалось заменить $self (скачайте скрипт $latest вручную), продолжаем с $RELEASE_TAG"
        return 0
    fi
    echo "Скрипт обновлён: $RELEASE_TAG -> $latest ($self). Запускаем новую версию..."
    rm -rf "$WORK_DIR"
    exec bash "$self" --update --no-self-update
}

update_matrix() {
    run_with_retry "ansible-playbook -i inventory/hosts setup.yml --tags=install-all,start" 3 \
        || die "обновление не удалось. Прошлый vars.yml сохранён рядом с ${UPDATE_CONFIG} как vars.yml.bak-ДАТА.
Повторить вручную: cd $REPO_DIR && sudo ansible-playbook -i inventory/hosts setup.yml --tags=install-all,start"
}

run_update() {
    load_proxy_env
    self_update
    ui_init
    ui_banner "Matrix · обновление · версия скрипта: $RELEASE_TAG" "плейбук matrix-docker-ansible-deploy $PLAYBOOK_VERSION"
    install_self
    REPO_DIR="$(find_repo_dir)"
    local configs=()
    local f
    for f in "$REPO_DIR"/inventory/host_vars/*/vars.yml; do
        [ -f "$f" ] && configs+=("$f")
    done
    [ "${#configs[@]}" -gt 0 ] || die "установка не найдена (нет $REPO_DIR/inventory/host_vars/*/vars.yml). Для новой установки запустите скрипт без --update"
    [ "${#configs[@]}" -eq 1 ] || die "в $REPO_DIR/inventory/host_vars несколько конфигов, обновляйте вручную: ${configs[*]}"
    [ -d "$REPO_DIR/.git" ] || die "$REPO_DIR не git-репозиторий, обновить плейбук скриптом нельзя"
    local cmd
    for cmd in ansible-playbook just docker git; do
        command -v "$cmd" > /dev/null || die "не найдена команда $cmd. Запустите скрипт без --update, он доустановит недостающее"
    done
    UPDATE_CONFIG="${configs[0]}"
    bridge_detect "$UPDATE_CONFIG"

    STEP_TOTAL=3
    [ "$BRIDGE_KIND" != remote ] || STEP_TOTAL=5
    run_step "Плейбук и роли" clone_playbook
    run_step "Версия плейбука в vars.yml" bump_validated_version "$UPDATE_CONFIG"
    STEP_HINT="до 30 минут, подробности: tail -f $LOG_FILE"
    run_step "Обновление Matrix" update_matrix
    [ "$BRIDGE_KIND" != remote ] || bridge_update_steps
    STEP_HINT=""

    ui_section "Обновление завершено!"
    ui_table \
        "Плейбук" "$REPO_DIR" \
        "Версия" "$PLAYBOOK_VERSION (коммит $(git -C "$REPO_DIR" rev-parse --short HEAD))" \
        "Конфиг" "$UPDATE_CONFIG" \
        "Мост Telegram" "$(bridge_status_text)"
}

# ---------- главный сценарий ----------

# Без параметров: на установленном сервере при ручном запуске - панель, иначе установка
if [ "$MODE" = auto ]; then
    if [ -t 0 ] && has_installation; then
        MODE=panel
    else
        MODE=install
    fi
fi

if [ "$MODE" = update ]; then
    run_update
    exit 0
fi

if [ "$MODE" = panel ]; then
    ui_init
    install_self
    run_panel
    exit 0
fi

ui_init
ui_banner "Matrix · установка · версия скрипта: $RELEASE_TAG" "Synapse, Element, звонки и уведомления через matrix-docker-ansible-deploy"
install_self
prepare_env_file
REPO_DIR="$(find_repo_dir)"
import_existing_vars
collect_input

STEP_TOTAL=9
[ "$NEED_XRAY" != yes ] || STEP_TOTAL=$((STEP_TOTAL + 1))
[ "$TG_BRIDGE" != remote ] || STEP_TOTAL=$((STEP_TOTAL + 4))
run_step "Системные пакеты" install_base
run_step "Swap" setup_swap
if [ "$NEED_XRAY" = yes ]; then
    run_step "Xray-прокси" setup_xray_and_proxy
else
    unset http_proxy https_proxy ftp_proxy no_proxy HTTP_PROXY HTTPS_PROXY FTP_PROXY NO_PROXY
fi
run_step "Docker" install_docker
run_step "Ansible и just" install_ansible
run_step "Плейбук matrix-docker-ansible-deploy" clone_playbook
run_step "Конфиг vars.yml" render_inventory
run_step "Firewall" setup_firewall
STEP_HINT="около 30 минут, подробности: tail -f $LOG_FILE"
run_step "Установка Matrix" install_matrix
STEP_HINT=""
run_step "Регистрация администратора" register_admin
if [ "$TG_BRIDGE" = remote ]; then
    run_step "Роль моста Telegram" bridge_fetch_role
    STEP_HINT="10–20 минут, подробности: tail -f $LOG_FILE"
    run_step "Установка моста на $TG_HOST" bridge_run_site
    if bridge_synapse_wired "$REPO_DIR/inventory/host_vars/$DOMAIN_MATRIX/vars.yml" > /dev/null; then
        run_step "Подключение моста к Synapse" note "Synapse уже подключён к мосту"
    else
        run_step "Подключение моста к Synapse" bridge_connect_synapse "$REPO_DIR/inventory/host_vars/$DOMAIN_MATRIX/vars.yml"
    fi
    STEP_HINT=""
    run_step "Проверка моста" bridge_verify
fi
print_summary

unset ADMIN_NICK ADMIN_PASS
