#!/bin/bash
# Установка Matrix (matrix-docker-ansible-deploy) и, по желанию, Xray-прокси.
#
# Значения берутся из файла .env рядом со скриптом. Недостающие значения спрашиваются
# и сохраняются в .env. Секреты генерируются один раз и тоже сохраняются, поэтому
# повторный запуск не меняет пароль БД и ключи уже установленного сервера.
# Шаблон конфига ansible (configs/vars.yml) скачивается из репозитория и заполняется из .env.
#
# Запуск: sudo ./matrix_up.sh

set -euo pipefail

RAW_BASE="https://raw.githubusercontent.com/kryptonmourog/matrix-instruction-and-configs/refs/tags/v1.1.0"
PLAYBOOK_REPO="https://github.com/spantaleev/matrix-docker-ansible-deploy.git"
PROXY_PORT=10809
DOCKER_BRIDGE_IP="172.17.0.1"

RED='\e[31m'
NC='\e[0m'
die() {
    printf "${RED}Ошибка: %s${NC}\n" "$*" >&2
    exit 1
}

if [ "$(id -u)" -ne 0 ]; then
    die "запустите скрипт через sudo: sudo ./matrix_up.sh"
fi

# Домашний каталог того, кто запустил sudo (а не /root)
TARGET_USER="${SUDO_USER:-root}"
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
[ -n "$TARGET_HOME" ] || die "не удалось определить домашний каталог пользователя $TARGET_USER"
REPO_DIR="$TARGET_HOME/matrix-docker-ansible-deploy"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"

# Рабочая папка для скачанных файлов. Удаляется при любом выходе.
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

touch "$ENV_FILE"
chmod 600 "$ENV_FILE"

# Функция для запуска тяжелых команд с несколькими попытками
run_with_retry() {
    local max_attempts=15
    local iterator=1
    local cmd="$1"

    while [ "$iterator" -le "$max_attempts" ]; do
        echo "Запуск: $cmd (Попытка $iterator)"
        if eval "$cmd"; then
            echo "Команда '$cmd' выполнена успешно!"
            return 0
        fi
        echo "Ошибка при выполнении. Повтор через 5 секунд..."
        sleep 5
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

# ask ПЕРЕМЕННАЯ "подсказка" функция_проверки
# Берёт значение из .env, если оно там есть; иначе спрашивает и сохраняет.
ask() {
    local var="$1" prompt="$2" check="$3" value
    value="$(env_get "$var")"
    if [ -z "$value" ]; then
        while true; do
            read -r -p "$prompt: " value
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

# ---------- проверки ввода ----------

is_ipv4() {
    local IFS=. o x
    [[ "$1" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 1
    read -ra o <<< "$1"
    for x in "${o[@]}"; do
        [ "$((10#$x))" -le 255 ] || return 1
    done
}
is_domain()   { [[ "$1" =~ ^([a-z0-9]([a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,}$ ]]; }
is_email()    { [[ "$1" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]]; }
is_nick()     { [[ "$1" =~ ^[a-z0-9._=-]+$ ]]; }
is_vless()    { [[ "$1" =~ ^vless:// ]]; }
is_password() {
    [ "${#1}" -ge 8 ] || return 1
    case "$1" in
        *[[:space:]\'\"\\\$\`!]*) return 1 ;;
    esac
    return 0
}

# ---------- шаг 1: все вопросы сразу, дальше установка идёт без участия ----------

collect_input() {
    echo "=== Параметры сервера (сохраняются в $ENV_FILE) ==="
    ask YOUR_IP            "IP (v4) сервера" is_ipv4
    ask DOMAIN             "Основной домен (например, example.com)" is_domain
    ask DOMAIN_MATRIX      "Поддомен для Matrix (например, mat.example.com)" is_domain
    ask DOMAIN_WEB_CLIENT  "Поддомен для Element Web (например, elem.example.com)" is_domain
    ask DOMAIN_ADMIN_PANEL "Поддомен для Element Admin (например, admin.example.com)" is_domain
    ask DOMAIN_COTURN      "Поддомен для Coturn (например, turn.example.com)" is_domain
    ask DOMAIN_CALL        "Поддомен для Element Call (например, call.example.com)" is_domain
    ask DOMAIN_NTFY        "Поддомен для ntfy (например, ntfy.example.com)" is_domain
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
        read -rs -p "Пароль админа (от 8 символов, без пробелов и знаков ! \" ' \\ \$ \`): " ADMIN_PASS
        echo
        is_password "$ADMIN_PASS" && break
        echo "  Некорректный пароль."
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

    # /etc/environment: убираем только строки прокси, остальное сохраняем (раньше файл перезаписывался целиком)
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

clone_playbook() {
    if [ ! -d "$REPO_DIR" ]; then
        git clone "$PLAYBOOK_REPO" "$REPO_DIR"
    fi
    cd "$REPO_DIR" || die "директория $REPO_DIR недоступна"
    run_with_retry "just update"
}

# ---------- шаг 5: inventory и vars.yml из шаблона ----------

render_inventory() {
    echo "=== Конфиг ansible ==="
    mkdir -p "inventory/host_vars/$DOMAIN_MATRIX"
    printf '[matrix_servers]\n%s ansible_host=127.0.0.1 ansible_connection=local\n' "$DOMAIN_MATRIX" > inventory/hosts

    download "$RAW_BASE/configs/vars.yml" "$WORK_DIR/vars.yml.tpl"
    local out="inventory/host_vars/$DOMAIN_MATRIX/vars.yml"

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

install_playbook() {
    echo "Запускаем установку Matrix. Это займет ~30 минут..."
    run_with_retry "ansible-playbook -i inventory/hosts setup.yml --tags=install-all,start"

    echo "=== Регистрация администратора ==="
    # Пароль передаётся файлом, а не в командной строке (в командной строке он виден в ps)
    local vars_file="$WORK_DIR/admin-vars.json"
    (umask 077 && python3 -c 'import json,sys; print(json.dumps({"username": sys.argv[1], "password": sys.argv[2], "admin": "yes"}))' "$ADMIN_NICK" "$ADMIN_PASS" > "$vars_file")
    ansible-playbook -i inventory/hosts setup.yml --extra-vars "@$vars_file" --tags=register-user
}

print_summary() {
    printf "\n\n\n%s\n\n" "Установка завершена!"
    if [ "$NEED_XRAY" = yes ]; then
        printf "Ваш XRAY-конфиг доступен по пути:\n%s\n\n" "/usr/local/etc/xray/config.json"
    else
        printf "Вы отказались от установки XRAY\n\n"
    fi
    printf "Ваш ansible-конфиг доступен по пути:\n%s\n\n" "$REPO_DIR/inventory/host_vars/$DOMAIN_MATRIX/vars.yml"
    printf "Ваши параметры и секреты (для повторных запусков):\n%s\n\n" "$ENV_FILE"
    printf "Команда для повторного запуска ansible (если будете менять конфиг):\n%s\n\n" "ansible-playbook -i inventory/hosts setup.yml --tags=setup-all,start"
    printf "Адрес вашего homeserver Matrix:\n%s\n\n" "$DOMAIN_MATRIX"
    printf "Адрес вашего web-клиента Matrix:\n%s\n\n" "$DOMAIN_WEB_CLIENT"
    printf "Адрес вашей админки Matrix:\n%s\n\n" "$DOMAIN_ADMIN_PANEL"
    printf "Никнейм админа:\n%s\n\n" "$ADMIN_NICK"
    printf "Пароль админа:\n%s\n\n" "$ADMIN_PASS"
}

# ---------- главный сценарий ----------

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
