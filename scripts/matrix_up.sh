#!/bin/bash
# Установка Matrix (matrix-docker-ansible-deploy) и, по желанию, Xray-прокси.
#
# Значения берутся из файла .env рядом со скриптом. Недостающие значения спрашиваются
# и сохраняются в .env. Секреты генерируются один раз и тоже сохраняются, поэтому
# повторный запуск не меняет пароль БД и ключи уже установленного сервера.
# Если на сервере уже есть установка (в том числе сделанная версией v1.0.0),
# значения и секреты берутся из её vars.yml.
# Шаблон конфига ansible (configs/vars.yml) скачивается из репозитория и заполняется из .env.
#
# Запуск: sudo ./matrix_up.sh

set -euo pipefail

RELEASE_TAG="v1.1.1"
RAW_BASE="https://raw.githubusercontent.com/kryptonmourog/matrix-instruction-and-configs/refs/tags/${RELEASE_TAG}"
PLAYBOOK_REPO="https://github.com/spantaleev/matrix-docker-ansible-deploy.git"
# У плейбука нет git-тегов, поэтому он фиксируется по коммиту, на котором проверен этот релиз.
# PLAYBOOK_VERSION должна совпадать с matrix_playbook_migration_validated_version в configs/vars.yml.
PLAYBOOK_COMMIT="53bf00e192e971b72bb62c0d28f0d5599eb97cae"
PLAYBOOK_VERSION="v2026.05.18.0"
PROXY_PORT=10809
DOCKER_BRIDGE_IP="172.17.0.1"

RED='\e[31m'
YELLOW='\e[33m'
NC='\e[0m'
die() {
    printf "${RED}Ошибка: %s${NC}\n" "$*" >&2
    exit 1
}
warn() {
    printf "${YELLOW}Внимание: %s${NC}\n" "$*" >&2
}

if [ "$(id -u)" -ne 0 ]; then
    die "запустите скрипт через sudo: sudo ./matrix_up.sh"
fi

TARGET_USER="${SUDO_USER:-root}"
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
[ -n "$TARGET_HOME" ] || die "не удалось определить домашний каталог пользователя $TARGET_USER"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"

# Рабочая папка для скачанных файлов. Удаляется при любом выходе.
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

touch "$ENV_FILE" || die "не удалось создать $ENV_FILE. Скачайте скрипт в обычную папку (curl -O ...) и запустите его оттуда"
chmod 600 "$ENV_FILE"

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

# ask ПЕРЕМЕННАЯ "подсказка" функция_проверки [функция_нормализации]
# Берёт значение из .env, если оно там есть; иначе спрашивает и сохраняет.
ask() {
    local var="$1" prompt="$2" check="$3" normalize="${4:-}" value
    value="$(env_get "$var")"
    if [ -z "$value" ]; then
        while true; do
            read -r -p "$prompt: " value
            if [ -n "$normalize" ]; then
                value="$("$normalize" "$value")"
            fi
            if "$check" "$value"; then
                break
            fi
            echo "  Некорректное значение, попробуйте ещё раз."
        done
        env_set "$var" "$value"
    fi
    printf -v "$var" '%s' "$value"
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

    echo "=== Найдена прошлая установка: $existing ==="
    echo "Её домены и секреты переносятся в $ENV_FILE, пароль БД и ключи не изменятся."
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
}
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
            found[mapping[key]] = value
found["NEED_XRAY"] = "yes" if uses_proxy else "no"
for key, value in found.items():
    print(f"{key}\t{value}")
PY
    while IFS=$'\t' read -r key value; do
        [ -n "$value" ] || continue
        if [ -z "$(env_get "$key")" ]; then
            env_set "$key" "$value"
        fi
    done < "$imported"

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

# ---------- шаг 1: все вопросы сразу, дальше установка идёт без участия ----------

collect_input() {
    echo "=== Параметры сервера (сохраняются в $ENV_FILE) ==="
    ask YOUR_IP            "IP (v4) сервера" is_ipv4
    ask DOMAIN             "Основной домен (например, example.com)" is_domain normalize_domain
    ask DOMAIN_MATRIX      "Поддомен для Matrix (например, mat.example.com)" is_domain normalize_domain
    ask DOMAIN_WEB_CLIENT  "Поддомен для Element Web (например, elem.example.com)" is_domain normalize_domain
    ask DOMAIN_ADMIN_PANEL "Поддомен для Element Admin (например, admin.example.com)" is_domain normalize_domain
    ask DOMAIN_COTURN      "Поддомен для Coturn (например, turn.example.com)" is_domain normalize_domain
    ask DOMAIN_CALL        "Поддомен для Element Call (например, call.example.com)" is_domain normalize_domain
    ask DOMAIN_NTFY        "Поддомен для ntfy (например, ntfy.example.com)" is_domain normalize_domain
    ask ADMIN_EMAIL        "Email для SSL-уведомлений (Let's Encrypt)" is_email

    NEED_XRAY="$(env_get NEED_XRAY)"
    if [ -z "$NEED_XRAY" ]; then
        read -r -p "Ваш сервер находится в РФ и нужен Xray прокси (потребуется vless-ссылка)? [y/N]: " answer
        if [[ "$answer" =~ ^[Yy]$ ]]; then
            NEED_XRAY=yes
        else
            NEED_XRAY=no
        fi
        env_set NEED_XRAY "$NEED_XRAY"
    fi

    VLESS_LINK=""
    if [ "$NEED_XRAY" = yes ]; then
        ask VLESS_LINK "vless-ссылка (vless://uuid@host:port?params...)" is_vless
    fi

    # Секреты: генерируются один раз, потом берутся из .env
    ensure_secret GENERIC_SECRET
    ensure_secret DB_PASSWORD
    ensure_secret COTURN_SECRET
    ensure_secret MAS_ENC_KEY

    echo "=== Администратор Matrix (в .env не сохраняется) ==="
    while true; do
        read -r -p "Логин админа (нижний регистр, латиница/цифры, символы ._=-): " ADMIN_NICK
        is_nick "$ADMIN_NICK" && break
        echo "  Некорректный логин."
    done
    while true; do
        read -rs -p "Пароль админа (от 12 символов, строчные и заглавные буквы и цифры; Enter — сгенерировать): " ADMIN_PASS
        echo
        if [ -z "$ADMIN_PASS" ]; then
            ADMIN_PASS="$(openssl rand -base64 24 | tr -d '+/=\n')"
            echo "  Пароль сгенерирован, он будет показан в конце установки."
            break
        fi
        is_password "$ADMIN_PASS" && break
        echo "  Слишком простой пароль: нужно от 12 символов, строчные и заглавные буквы, цифры, без пробелов."
    done
}

# ---------- шаг 2: базовые пакеты и swap ----------

install_base() {
    echo "=== Базовые пакеты ==="
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get upgrade -y
    apt-get install -y curl git python3 python3-pip wget ufw openssl software-properties-common
}

setup_swap() {
    echo "=== Swap ==="
    if swapon --show=NAME --noheadings | grep -qx /swapfile; then
        echo "Swap-файл уже включён, пропускаем"
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
    echo "=== Xray ==="
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
    echo "Xray установлен и запущен"
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

    # Прокси для докера
    mkdir -p /etc/systemd/system/docker.service.d
    cat > /etc/systemd/system/docker.service.d/http-proxy.conf <<EOF
[Service]
Environment="HTTP_PROXY=http://${DOCKER_BRIDGE_IP}:${PROXY_PORT}"
Environment="HTTPS_PROXY=http://${DOCKER_BRIDGE_IP}:${PROXY_PORT}"
Environment="NO_PROXY=localhost,127.0.0.1,::1,${YOUR_IP},${DOMAIN},.${DOMAIN},172.16.0.0/12,10.0.0.0/8,fd42:f167:100f::/48"
EOF
}

# ---------- шаг 4: docker, ansible, репозиторий плейбука ----------

install_docker() {
    echo "=== Docker ==="
    run_with_retry "curl -fsSL https://get.docker.com | sh"
    systemctl enable --now docker
    systemctl daemon-reload
    systemctl restart docker
    echo "Подготовка образа Element Admin..."
    run_with_retry "docker pull oci.element.io/element-admin:latest"
}

install_ansible() {
    echo "=== Ansible и just ==="
    add-apt-repository --yes --update ppa:ansible/ansible
    if ! command -v just > /dev/null 2>&1; then
        curl --proto '=https' --tlsv1.2 -sSf https://just.systems/install.sh | bash -s -- --to /usr/local/bin
    fi
    apt-get install -y ansible
}

# Плейбук фиксируется на PLAYBOOK_COMMIT. Уже установленный плейбук новее этой версии
# не откатывается: откат может сломать базу данных Synapse.
clone_playbook() {
    echo "=== Плейбук matrix-docker-ansible-deploy ==="
    if [ ! -d "$REPO_DIR/.git" ]; then
        [ ! -e "$REPO_DIR" ] || die "$REPO_DIR существует, но это не git-репозиторий. Переименуйте его и запустите скрипт снова"
        local partial="$REPO_DIR.partial"
        run_with_retry "rm -rf '$partial' && git clone -q '$PLAYBOOK_REPO' '$partial'"
        mv "$partial" "$REPO_DIR"
        git -C "$REPO_DIR" checkout -q "$PLAYBOOK_COMMIT"
        echo "Плейбук зафиксирован на коммите $PLAYBOOK_COMMIT ($PLAYBOOK_VERSION)"
    else
        run_with_retry "git -C '$REPO_DIR' fetch -q origin"
        if git -C "$REPO_DIR" merge-base --is-ancestor "$PLAYBOOK_COMMIT" HEAD; then
            echo "Плейбук в $REPO_DIR уже не старше проверенной версии, оставляем его как есть"
        else
            git -C "$REPO_DIR" checkout -q "$PLAYBOOK_COMMIT" \
                || die "не удалось переключить плейбук на $PLAYBOOK_COMMIT: в $REPO_DIR есть локальные изменения"
            echo "Плейбук переключён на коммит $PLAYBOOK_COMMIT ($PLAYBOOK_VERSION)"
        fi
    fi
    cd "$REPO_DIR" || die "директория $REPO_DIR недоступна"
    # 'just update' сделал бы git pull и ушёл с зафиксированной версии, поэтому только роли
    run_with_retry "just roles"
}

# ---------- шаг 5: inventory и vars.yml из шаблона ----------

render_inventory() {
    echo "=== Конфиг ansible ==="
    mkdir -p "inventory/host_vars/$DOMAIN_MATRIX"
    printf '[matrix_servers]\n%s ansible_host=127.0.0.1 ansible_connection=local\n' "$DOMAIN_MATRIX" > inventory/hosts

    download "$RAW_BASE/configs/vars.yml" "$WORK_DIR/vars.yml.tpl"
    local out="inventory/host_vars/$DOMAIN_MATRIX/vars.yml"

    # Прошлый vars.yml (возможно, с ручными правками) сохраняем рядом
    if [ -f "$out" ]; then
        local backup
        backup="$out.bak-$(date +%Y%m%d-%H%M%S)"
        cp -p "$out" "$backup"
        echo "Прошлый vars.yml сохранён: $REPO_DIR/$backup"
    fi

    python3 - "$WORK_DIR/vars.yml.tpl" "$ENV_FILE" "$out" "$NEED_XRAY" <<'PY' || die "не удалось собрать vars.yml"
import re
import sys

template_path, env_path, out_path, need_xray = sys.argv[1:5]

values = {}
with open(env_path, encoding="utf-8") as f:
    for line in f:
        m = re.match(r'^([A-Z_][A-Z0-9_]*)="(.*)"$', line.rstrip("\n"))
        if m:
            values[m.group(1)] = m.group(2)

# Блоки между маркерами нужны только при использовании Xray
keep_xray = need_xray == "yes"
kept, skipping = [], False
with open(template_path, encoding="utf-8") as f:
    for line in f:
        marker = line.strip()
        if marker == "# @XRAY_BEGIN":
            skipping = not keep_xray
            continue
        if marker == "# @XRAY_END":
            skipping = False
            continue
        if not skipping:
            kept.append(line)

text = "".join(kept)
placeholder = re.compile(r"\$\{([A-Z_][A-Z0-9_]*)\}")
missing = sorted({name for name in placeholder.findall(text) if not values.get(name)})
if missing:
    sys.exit("В .env не заполнены переменные: " + ", ".join(missing))
text = placeholder.sub(lambda m: values[m.group(1)], text)

with open(out_path, "w", encoding="utf-8") as f:
    f.write(text)
PY
    chmod 600 "$out"
}

# ---------- шаг 6: firewall ----------

setup_firewall() {
    echo "=== Firewall ==="
    local rule
    for rule in 22/tcp 80/tcp 443/tcp 3478/tcp 3478/udp 5349/tcp 5349/udp \
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

install_playbook() {
    echo "Запускаем установку Matrix. Это займет ~30 минут..."
    # Повторы помогают при сетевых сбоях. Ошибки DNS и сертификатов они не лечат,
    # поэтому попыток мало, а при неудаче выводим, что проверить.
    run_with_retry "ansible-playbook -i inventory/hosts setup.yml --tags=install-all,start" 3 \
        || die "установка Matrix не удалась (подробности выше). Частые причины:
  - DNS-записи доменов ($DOMAIN, $DOMAIN_MATRIX, $DOMAIN_WEB_CLIENT, $DOMAIN_ADMIN_PANEL, $DOMAIN_COTURN, $DOMAIN_CALL, $DOMAIN_NTFY) не указывают на $YOUR_IP;
  - порты 80 и 443 недоступны из интернета, и Let's Encrypt не может выдать сертификаты.
После исправления повторите: cd $REPO_DIR && sudo ansible-playbook -i inventory/hosts setup.yml --tags=install-all,start
Или запустите этот скрипт снова: значения и секреты возьмутся из $ENV_FILE"

    echo "=== Регистрация администратора ==="
    # Пароль передаётся файлом, а не в командной строке (в командной строке он виден в ps)
    local vars_file="$WORK_DIR/admin-vars.json"
    (umask 077 && python3 -c 'import json,sys; print(json.dumps({"username": sys.argv[1], "password": sys.argv[2], "admin": "yes"}))' "$ADMIN_NICK" "$ADMIN_PASS" > "$vars_file")
    # Ошибка регистрации не должна обесценивать уже выполненную установку
    if ansible-playbook -i inventory/hosts setup.yml --extra-vars "@$vars_file" --tags=register-user; then
        ADMIN_REGISTERED=yes
    else
        warn "администратор не зарегистрирован (подробности выше)"
    fi
}

print_summary() {
    printf "\n\n\n%s\n\n" "Установка завершена!"
    if [ "$NEED_XRAY" = yes ]; then
        printf "Ваш XRAY-конфиг доступен по пути:\n%s\n\n" "/usr/local/etc/xray/config.json"
    else
        printf "Вы отказались от установки XRAY\n\n"
    fi
    printf "Ваш ansible-конфиг доступен по пути:\n%s\n\n" "$REPO_DIR/inventory/host_vars/$DOMAIN_MATRIX/vars.yml"
    printf "Ваши параметры и секреты (для повторных запусков, не теряйте):\n%s\n\n" "$ENV_FILE"
    printf "Команда для повторного запуска ansible (если будете менять vars.yml):\n%s\n\n" \
        "cd $REPO_DIR && sudo ansible-playbook -i inventory/hosts setup.yml --tags=setup-all,start"
    printf "Учтите: повторный запуск этого скрипта пересоздаёт vars.yml из шаблона, прошлый файл сохраняется рядом (vars.yml.bak-ДАТА).\n\n"
    printf "Адрес вашего homeserver Matrix:\n%s\n\n" "$DOMAIN_MATRIX"
    printf "Адрес вашего web-клиента Matrix:\n%s\n\n" "$DOMAIN_WEB_CLIENT"
    printf "Адрес вашей админки Matrix:\n%s\n\n" "$DOMAIN_ADMIN_PANEL"
    printf "Никнейм админа:\n%s\n\n" "$ADMIN_NICK"
    printf "Пароль админа:\n%s\n\n" "$ADMIN_PASS"
    if [ "$ADMIN_REGISTERED" != yes ]; then
        warn "администратор не зарегистрирован. Частые причины: такой пользователь уже есть, или MAS счёл пароль слишком простым."
        printf "Зарегистрировать вручную:\n%s\n\n" \
            "cd $REPO_DIR && sudo ansible-playbook -i inventory/hosts setup.yml --extra-vars='username=ЛОГИН password=ПАРОЛЬ admin=yes' --tags=register-user"
    fi
}

# ---------- главный сценарий ----------

REPO_DIR="$(find_repo_dir)"
import_existing_vars
collect_input
install_base
setup_swap

if [ "$NEED_XRAY" = yes ]; then
    setup_xray
    setup_proxy
else
    echo "Пропускаем настройку Xray. Прокси не будет использован."
    unset http_proxy https_proxy ftp_proxy no_proxy HTTP_PROXY HTTPS_PROXY FTP_PROXY NO_PROXY
fi

install_docker
install_ansible
clone_playbook
render_inventory
setup_firewall
install_playbook
print_summary

unset ADMIN_NICK ADMIN_PASS
