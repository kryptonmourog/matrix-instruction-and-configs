#!/bin/bash

read -r -p "Введите IP (v4) сервера: " YOUR_IP
read -r -p "Введите ваш основной домен (например, example.com): " DOMAIN
# ОПРЕДЕЛЕНИЕ ТЕХНИЧЕСКИХ ДОМЕНОВ (Важно для путей!)
read -r -p "Поддомен для Matrix (например, mat.example.com): " DOMAIN_MATRIX
read -r -p "Поддомен для Element Web (например, elem.example.com): " DOMAIN_WEB_CLIENT
read -r -p "Поддомен для Element Admin (например, admin.example.com): " DOMAIN_ADMIN_PANEL
read -r -p "Поддомен для Coturn (например, turn.example.com): " DOMAIN_COTURN
read -r -p "Поддомен для Element Call (например, call.example.com): " DOMAIN_CALL
read -r -p "Поддомен для ntfy (сервис уведомлений) (например, ntfy.example.com): " DOMAIN_NTFY

read -r -p "Введите желаемый логин для Админа Matrix (в нижнем_регистре): " ADMIN_NICK
read -r -p "Введите желаемый пароль для Админа Matrix (без восклицательных знаков): " ADMIN_PASS
# Запрос email для SSL (Let's Encrypt)
read -r -p "Введите ваш Email для SSL-уведомлений (от Let's Encrypt): " ADMIN_EMAIL
# Опрос пользователя касаемо XRAY vless/reality
read -r -p "Ваш сервер находится в РФ и вам нужен Xray прокси (потребуется vless ссылка)? [y/N]: " NEED_XRAY

if [[ "$NEED_XRAY" =~ ^[Yy]$ ]]; then
    read -r -p "Введите вашу VLESS ссылку (vless://uuid@host:port?params...): " VLESS_LINK
fi


# Генерация случайных паролей
GENERIC_SECRET=$(openssl rand -hex 32)
DB_PASSWORD=$(openssl rand -hex 32)
COTURN_SECRET=$(openssl rand -hex 32)
MAS_ENC_KEY=$(openssl rand -hex 32)

# Установка базовых зависимостей
sudo apt update && sudo apt upgrade -y
sudo apt install curl git python3 python3-pip wget -y

# Создание swap-файла
sudo fallocate -l 4G /swapfile
sudo chmod 600 /swapfile
sudo mkswap /swapfile
sudo swapon /swapfile
echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
sudo sysctl vm.swappiness=10
echo 'vm.swappiness=10' | sudo tee -a /etc/sysctl.conf

# Настройка XRAY
if [[ "$NEED_XRAY" =~ ^[Yy]$ ]]; then
    # Парсинг VLESS ссылки
    # Убираем протокол
    VLESS_STR=${VLESS_LINK#vless://}
    # Извлекаем UUID (всё до @)
    V_UUID=$(echo "$VLESS_STR" | cut -d'@' -f1)
    # Извлекаем остальное
    V_REMAIN=$(echo "$VLESS_STR" | cut -d'@' -f2)
    # Извлекаем адрес и порт
    V_ADDR_PORT=$(echo "$V_REMAIN" | cut -d'?' -f1)
    V_ADDR=$(echo "$V_ADDR_PORT" | cut -d':' -f1)
    V_PORT=$(echo "$V_ADDR_PORT" | cut -d':' -f2)

    # Извлекаем параметры (всё после ?)
    V_PARAMS=$(echo "$V_REMAIN" | cut -d'?' -f2 | cut -d'#' -f1)

    # Функция для извлечения конкретных параметров из строки
    get_vless_param() {
        echo "$V_PARAMS" | grep -oP "$1=\K[^&]+" | sed 's/%2F/\//g'
    }

    V_PBK=$(get_vless_param "pbk")
    V_SNI=$(get_vless_param "sni")
    V_SID=$(get_vless_param "sid")
    V_FP=$(get_vless_param "fp")
    V_TYPE=$(get_vless_param "type")
    V_SECURITY=$(get_vless_param "security")
    V_FLOW=$(get_vless_param "flow")
    V_SPX=$(get_vless_param "spx")



    # Установка и настройка Xray
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
    sudo mkdir -p /usr/local/share/xray
    sudo wget https://github.com/runetfreedom/russia-v2ray-rules-dat/releases/latest/download/geosite.dat -O /usr/local/share/xray/geosite.dat
    sudo wget https://github.com/runetfreedom/russia-v2ray-rules-dat/releases/latest/download/geoip.dat -O /usr/local/share/xray/geoip.dat
    # Запись конфига с подставленными значениями
    sudo tee /usr/local/etc/xray/config.json <<EOF
{
  "log": { "loglevel": "info" },
  "inbounds": [
    {
      "tag": "socks-in",
      "port": 10808,
      "listen": "0.0.0.0",
      "protocol": "socks",
      "settings": { "auth": "noauth", "udp": true }
    },
    {
      "tag": "http-in",
      "port": 10809,
      "listen": "0.0.0.0",
      "protocol": "http",
      "settings": { "enabled": true, "allowTransparent": false }
    }
  ],
  "outbounds": [
    {
      "tag": "Personality-matrix_xray",
      "protocol": "vless",
      "settings": {
        "vnext": [
          {
// IP АДРЕС ВАШЕГО XRAY ПРОКСИ-СЕРВЕРА
            "address": "$V_ADDR",
            "port": $V_PORT,
            "users": [
              {
// ВАШ USER ID (то что стоит после "vless://" и до "@ip.вашего.сервера")
                "id": "$V_UUID",
                // encryption
                "encryption": "none",
                // flow
                "flow": "$V_FLOW"
              }
            ]
          }
        ]
      },
      "streamSettings": {
        // type
        "network": "${V_TYPE:-tcp}",
        // security
        "security": "$V_SECURITY",
        "realitySettings": {
          // pbk
          "publicKey": "$V_PBK",
          // fp
          "fingerprint": "$V_FP",
          // sni
          "serverName": "$V_SNI",
          // sid
          "shortId": "$V_SID",
          // spx
          "spiderX": "${V_SPX:-/}"
        },
        "xhttpSettings": {
          // path
          "path": "/",
          "mode": "auto",
          "extra": {
            "noGRPCHeader": false
          }
        }
      }
    },
    { "tag": "direct", "protocol": "freedom", "settings": { "domainStrategy": "UseIPv4" } },
    { "tag": "block", "protocol": "blackhole", "settings": {} }
  ],
  "dns": {
    "servers": [
      // Приоритетный DNS для СНГ доменов (быстрый, без прокси)
      {
        "address": "77.88.8.8",     // DNS Яндекса
        "port": 53,
        "expectIPs": ["geoip:ru"],
        "domains": [
          "geosite:ru-available-only-inside",
          "regexp:^.*\\\\.ru$",
          "regexp:\\\\.su$",
          "regexp:\\\\.kz$",
          "regexp:\\\\.by$",
          "regexp:\\\\.xn--p1acf$",    // .рус
          "regexp:\\\\.xn--80adxhks$", // .москва
          "regexp:\\\\.xn--p1ai$",     // .рф
          "regexp:\\\\.xn--90ais$"     // .бел
        ]
      },
      // Глобальные DNS для всего остального
      {
        "address": "1.1.1.1",       // DNS Cloudflare
        "port": 53,
        "domains": [] // "все остальные"
      },
      {
        "address": "8.8.8.8",       // DNS Google
        "port": 53,
        "domains": [] // "все остальные"
      }
    ],
    "queryStrategy": "UseIPv4"
  },
  "routing": {
    "domainStrategy": "AsIs",
    "rules": [
      // Локальный трафик - напрямую
      {
        "type": "field",
        "ip": [
          "geoip:private",
          "172.16.0.0/12",
          "10.0.0.0/8",
          "127.0.0.0/8",
          "fd42:f167:100f::/48"
        ],
        "outboundTag": "direct"
      },
      // Крупные зарубежные matrix-сервера - в прокси-сервер
      {
        "type": "field",
        "domain": [
          "matrix.org",          // Самый крупный узел
          "element.io",          // Разработчики и их инфраструктура
          "gitter.im",           // Мост с Gitter
          "mozilla.org",         // Сообщество Mozilla
          "kde.org",             // Сообщество KDE
          "gnome.org",           // Сообщество GNOME
          "t2l.io",              // Популярный хостинг ботов или мостов
          "grin.hu",             // Популярный хостинг ботов или мостов
          "fedora.im",           // Сообщество Fedora
          "matrix.v.systems",    // Популярный азиатский узел
          "modular.im"           // Хостинг для платных серверов
        ],
        "outboundTag": "Personality-matrix_xray"
      },
      // Российские IP - напрямую
      {
        "type": "field",
        "ip": ["geoip:ru"],
        "outboundTag": "direct"
      },
      // СНГ Домены - напрямую
      {
        "type": "field",
        "domain": [
          "geosite:ru-available-only-inside",
          "regexp:^.*\\\\.ru$",
          "regexp:\\\\.su$",
          "regexp:\\\\.kz$",
          "regexp:\\\\.by$",
          "regexp:\\\\.xn--p1acf$",    // .рус
          "regexp:\\\\.xn--80adxhks$", // .москва
          "regexp:\\\\.xn--p1ai$",     // .рф
          "regexp:\\\\.xn--90ais$"     // .бел
        ],
        "outboundTag": "direct"
      },
      // Всё остальное - в прокси-сервер
      {
        "type": "field",
        "network": "tcp,udp",
        "outboundTag": "Personality-matrix_xray"
      }
    ]
  }
}
EOF

    sudo systemctl restart xray
    echo "Ожидание перезапуска Xray..."
    sleep 15

    # Экспортируем переменные для прокси в ТЕКУЩУЮ сессию скрипта
    export http_proxy="http://127.0.0.1:10809"
    export https_proxy="http://127.0.0.1:10809"
    export ftp_proxy="http://127.0.0.1:10809"
    export no_proxy="localhost,127.0.0.1,::1,${YOUR_IP},${DOMAIN},.${DOMAIN},172.16.0.0/12,10.0.0.0/8,fd42:f167:100f::/48"
    export HTTP_PROXY="http://127.0.0.1:10809"
    export HTTPS_PROXY="http://127.0.0.1:10809"
    export FTP_PROXY="http://127.0.0.1:10809"
    export NO_PROXY="localhost,127.0.0.1,::1,${YOUR_IP},${DOMAIN},.${DOMAIN},172.16.0.0/12,10.0.0.0/8,fd42:f167:100f::/48"

    # Настройка системного прокси через /etc/environment
    sudo tee /etc/environment <<EOF
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/usr/games:/usr/local/games:/snap/bin"
http_proxy="http://127.0.0.1:10809"
https_proxy="http://127.0.0.1:10809"
ftp_proxy="http://127.0.0.1:10809"
no_proxy="localhost,127.0.0.1,::1,${YOUR_IP},${DOMAIN},.${DOMAIN},172.16.0.0/12,10.0.0.0/8,fd42:f167:100f::/48"
HTTP_PROXY="http://127.0.0.1:10809"
HTTPS_PROXY="http://127.0.0.1:10809"
FTP_PROXY="http://127.0.0.1:10809"
NO_PROXY="localhost,127.0.0.1,::1,${YOUR_IP},${DOMAIN},.${DOMAIN},172.16.0.0/12,10.0.0.0/8,fd42:f167:100f::/48"
EOF

    # Настройка прокси для Docker
    sudo mkdir -p /etc/systemd/system/docker.service.d
    sudo tee /etc/systemd/system/docker.service.d/http-proxy.conf <<EOF
[Service]
Environment="HTTP_PROXY=http://172.17.0.1:10809"
Environment="HTTPS_PROXY=http://172.17.0.1:10809"
Environment="NO_PROXY=localhost,127.0.0.1,::1,${YOUR_IP},${DOMAIN},.${DOMAIN},172.16.0.0/12,10.0.0.0/8,fd42:f167:100f::/48"
EOF

    # Если Есть прокси, то прописываем его для synapse (PROXY_URL будет использоваться в конфиге vars,yml)
    PROXY_URL="http://172.17.0.1:10809"
else
    echo "Пропускаем настройку Xray. Прокси не будет использован."
    # Очищаем переменные прокси, чтобы система не пыталась в них стучаться
    PROXY_URL=""
    http_proxy=""
    https_proxy=""
    ftp_proxy=""
    HTTP_PROXY=""
    FTP_PROXY=""
    HTTPS_PROXY=""
fi

# Установка докера через официальный скрипт
curl -fsSL https://get.docker.com -o get-docker.sh
sudo sh get-docker.sh

# Запуск и включение в автозагрузку
sudo systemctl enable --now docker
# Перезапуск всех фоновых процессов
sudo systemctl daemon-reload
sudo systemctl restart docker
# ЕСЛИ ставим Element Admin, то:
echo "Подготовка образа Element Admin..."
sudo docker pull oci.element.io/element-admin:latest

# Установка Ansible и подготовка репозитория
sudo apt install software-properties-common
sudo add-apt-repository --yes --update ppa:ansible/ansible

# Официальный скрипт для установки just (если в стандартных репозиториях его нет)
curl --proto '=https' --tlsv1.2 -sSf https://just.systems/install.sh | sudo bash -s -- --to /usr/local/bin
#ИЛИ
#echo "deb [signed-by=/usr/share/keyrings/azlux-archive-keyring.gpg] http://packages.azlux.fr/debian/ stable main" | sudo tee /etc/apt/sources.list.d/azlux.list
#sudo wget -O /usr/share/keyrings/azlux-archive-keyring.gpg https://azlux.fr/repo.gpg
#sudo apt update

sudo apt install ansible just -y

cd ~ || {
    printf "\e[31mОшибка: Не удалось перейти в папку текущего пользователя.\e[0m\n"
    exit 1
}
if [ ! -d "matrix-docker-ansible-deploy" ]; then
    git clone https://github.com/spantaleev/matrix-docker-ansible-deploy.git
fi
cd matrix-docker-ansible-deploy || {
    printf "\e[31mОшибка: Директория matrix-docker-ansible-deploy не найдена. Проверьте, прошел ли git clone.\e[0m\n"
    exit 1
}
sudo just update

# Создаем каталог для хранения вашей конфигурации
mkdir -p "inventory/host_vars/$DOMAIN_MATRIX"

# Создание файла hosts
echo "[matrix_servers]" > inventory/hosts
echo "$DOMAIN_MATRIX ansible_host=127.0.0.1 ansible_connection=local" >> inventory/hosts


# Создание vars.yml с подставленными значениями
sudo tee "inventory/host_vars/$DOMAIN_MATRIX/vars.yml" <<EOF
---

your_ip: "$YOUR_IP"
your_proxy_http_proxy: "$PROXY_URL"
your_proxy_no_proxy: "localhost,127.0.0.1,{{ matrix_domain }},.{{ matrix_domain }},matrix-synapse,matrix-authentication-service,matrix-postgres,matrix-exim-relay,172.16.0.0/12"

matrix_domain: "$DOMAIN"                                  # ВСТАВИТЬ свой ОСНОВНОЙ ДОМЕН
matrix_server_fqn_matrix: "$DOMAIN_MATRIX"                # ВСТАВИТЬ свой домен для MATRIX
coturn_hostname: "$DOMAIN_COTURN"                         # ВСТАВИТЬ свой домен для COTURN (старые звонки 1-на-1)
matrix_element_call_hostname: "$DOMAIN_CALL"              # ВСТАВИТЬ свой домен для Element Call (современные звонки + групповые)
ntfy_hostname: "$DOMAIN_NTFY"                             # ВСТАВИТЬ свой домен для NTFY (уведомления)
matrix_element_admin_hostname: "$DOMAIN_ADMIN_PANEL"      # ВСТАВИТЬ свой домен для Element Admin
matrix_server_fqn_element: "$DOMAIN_WEB_CLIENT"           # ВСТАВИТЬ свой домен для Web CLient (Element Web)


# Проверка версии плейбука
matrix_playbook_migration_validated_version: v2026.04.03.0

# Это заставит matrix-клиенты искать настройки по адресу *ваш домен*/.well-known/matrix/client
matrix_well_known_matrix_client_enabled: true

# Для федерации
matrix_static_files_container_labels_base_domain_enabled: true

# обратный прокси - traefik - дефолт для этого ansible playbook
matrix_playbook_reverse_proxy_type: playbook-managed-traefik
traefik_config_certificatesResolvers_acme_email: '$ADMIN_EMAIL'   # ВСТАВИТЬ EMAIL ДЛЯ ИНФОРМАЦИИ ОБ SSL СЕРТИФИКАТОВ ОТ  LET'S ENCRYPT

# Настройки для Synapse
matrix_homeserver_implementation: synapse
matrix_homeserver_generic_secret_key: '$GENERIC_SECRET'           # ВСТАВИТЬ КАКОЙ-ТО СЕКРЕТНЫЙ КЛЮЧ (для матрикс-сервера)

# Глобальный таймаут Ansible (время ожидания ответа от системы)
# Время, которое дается systemd для перезапуска сервисов (секунды)
devture_systemd_service_manager_up_verification_delay_seconds: 600
# Увеличиваем таймаут запуска в самом systemd (в секундах)
matrix_synapse_systemd_service_specific_options: |
  TimeoutStartSec=600
# Настройки для Element Admin (часто падает из-за ещё не работающих зависимостей)
matrix_element_admin_systemd_service_specific_options: |
  TimeoutStartSec=300
  TimeoutStopSec=60
  TimeoutStopSec=60

postgres_connection_password: '$DB_PASSWORD'                      # ВСТАВИТЬ КАКОЙ-ТО ПАРОЛЬ ДЛЯ БД

# (Если у вас сервер - Synapse и не используется MAS, то настраиваем это на true)
# true Включает возможность самостоятельной регистрации
matrix_synapse_enable_registration: false
# Капча (требует доп. настройки поставщика капчи)
matrix_synapse_enable_registration_captcha: false
# Разрешает регистрационные токены Synapse (у MAS свои токены и настройка для них)
matrix_synapse_registration_requires_token: false
# Ограничение на размер скачиваемых файлов (число в мегабайтах, по дефолту было 50мб)
matrix_synapse_max_upload_size_mb: 2048

# Поиск пользователей

# Определяет, кого Synapse вообще включает в поисковый индекс.
# false: В поиске появятся только те пользователи,
#    с которыми у вас есть общие комнаты.
# true: В поиске будут доступны все зарегистрированные пользователи вашего сервера,
#    даже если вы с ними никак не пересекались.
matrix_synapse_user_directory_search_all_users: true
# Влияет на ранжирование (порядок выдачи) в результатах поиска.
# false: Результаты сортируются по релевантности (совпадению букв),
#    без приоритета места регистрации.
# true: Ваши «местные» пользователи (зарегистрированные на @ваш-домен.com)
#    будут всегда отображаться вверху списка, даже если есть более точные совпадения с пользователями
#    из других серверов (федерации).
matrix_synapse_user_directory_prefer_local_users: true
# Фильтр-отсечка для внешней федерации.
# false: В поиске могут появляться пользователи с других серверов
#    (если ваш сервер о них знает, например, через общие комнаты).
# true: Полностью запрещает показ любых пользователей в поиске c других серверов.
#    Вы будете видеть только тех, кто зарегистрирован лично на вашем сервере.
matrix_synapse_user_directory_exclude_remote_users: false

# Срок жизни медиа-файлов ВАШЕГО сервера от ваших пользователей (пусто = файлы живут вечно)
matrix_synapse_media_retention_local_media_lifetime:
# Срок жизни медиа-файлов со СТОРОННИХ серверов от других пользователей.
# Настройка: 7 дней - 7d, 2 недели - 2w, 1 месяц - 1m, 1 год - 1y
matrix_synapse_media_retention_remote_media_lifetime: 2w

# ntfy для уведомлений
ntfy_enabled: true
# Для ntfy Настройки прокси и DNS
ntfy_container_extra_arguments:
  - "--env"
  - "http_proxy={{ your_proxy_http_proxy }}"
  - "--env"
  - "https_proxy={{ your_proxy_http_proxy }}"
  - "--env"
  - "no_proxy={{ your_proxy_no_proxy }}"
  - "--dns"
  - "127.0.0.11"

# Явно говорим synapse где искать локальный ntfy
matrix_synapse_container_extra_hosts:
  - "{{ ntfy_hostname }}:host-gateway"

# Для Synapse настройки прокси, DNS и уведомления
matrix_synapse_container_extra_arguments:
  - "--add-host={{ ntfy_hostname }}:host-gateway"
  - "--env"
  - "http_proxy={{ your_proxy_http_proxy }}"
  - "--env"
  - "https_proxy={{ your_proxy_http_proxy }}"
  - "--env"
  # Без прокси: все локальные адреса, ваши домены,
  #  матрикс-контейнеры, которые могут общаться между собой по https (например Synapse <-> MAS) и все локальные адреса докера
  - "no_proxy={{ your_proxy_no_proxy }}"
  # Внутренний DNS докера
  - "--dns"
  - "127.0.0.11"

# Дополнительные настройки Synapse
matrix_synapse_configuration_extension_yaml: |
  #Список комнат, в которые пользователь попадет сразу после регистрации
  #auto_join_rooms:
  #  - "#your-room:your-server.com"
  #белые списки Synapse чтобы он мог обращаться к другим сервисам по локальному ip (важно для работающих уведомлений)
  ip_range_whitelist:
    - "172.16.0.0/12"
    - "10.0.0.0/8"
    - "127.0.0.0/8"
    - "192.168.0.0/16"

# Настраиваем ограничения сервера synapse чтобы не нагружать процессор огромными matrix-комнатами
matrix_synapse_limit_remote_rooms_enabled: true
matrix_synapse_limit_remote_rooms_complexity: 15.0
matrix_synapse_limit_remote_rooms_complexity_error: "Наш сервер не может подключаться к таким большим/тяжелым комнатам."
matrix_synapse_limit_remote_rooms_admins_can_join: false
# Если false - Убирает опросы online/offline - важно при федерации, иначе CPU будет постоянно нагружен
matrix_synapse_presence_enabled: false

# Звонки p2p
coturn_enabled: true
coturn_turn_external_ip_addresses: ["{{ your_ip }}"]
coturn_turn_static_auth_secret: "$COTURN_SECRET"                   # ВСТАВИТЬ КАКОЙ-ТО СЕКРЕТНЫЙ КЛЮЧ (для звонков через coturn)
coturn_turn_udp_min_port: 49152
coturn_turn_udp_max_port: 49652

# Групповые звонки через Element Call (livekit)
matrix_rtc_enabled: true
matrix_element_call_enabled: true
matrix_client_element_jitsi_preferred: false
matrix_client_element_voip_conference_type: "livekit"
# Принуждаем LiveKit работать корректно через TCP, если UDP блокируют
livekit_server_config_turn_external_tls: true
livekit_server_configuration_extension_yaml: |
  rtc:
    force_tcp: true

# Если сервер не знает своего внешнего IP, пакеты застревают
livekit_rtc_use_external_ip: true
livekit_rtc_external_ip: "{{ your_ip }}"

# Если включен MAS, то лучше использовать element_admin, а не synapse_admin
matrix_element_admin_enabled: true


# Настройка Matrix Authentication Service (MAS)
matrix_authentication_service_enabled: true
matrix_authentication_service_config_secrets_encryption: "$MAS_ENC_KEY"     # ВСТАВИТЬ КАКОЙ-ТО ПАРОЛЬ для MAS
# Если вы переносите авторизацию с обычного способа на MAS, то нужно поставить true
matrix_authentication_service_migration_in_progress: false

# Позволяет пользователям логиниться, используя email вместо username (удобно для сброса, но нужно настраивать отдельно)
matrix_authentication_service_config_account_login_with_email_allowed: false
# Включаем возможность регистрации по паролю, а не только через сторонних auth-поставщиков
matrix_authentication_service_config_account_password_registration_enabled: true
# Требовать токен для регистрации
matrix_authentication_service_config_account_registration_token_required: true
# Требовать email при регистрации
matrix_authentication_service_config_account_password_registration_email_required: false
# Позволяет пользователям самостоятельно Сбрасывать пароль по почте (нужно настроить работу с почтой на вашем сервере)
matrix_authentication_service_config_account_password_recovery_enabled: false
# Позволяет пользователям самостоятельно Менять пароль в настройках
matrix_authentication_service_config_account_password_change_allowed: true

# Настройки прокси для MAS
matrix_authentication_service_container_extra_arguments:
  - "--env"
  - "http_proxy={{ your_proxy_http_proxy }}"
  - "--env"
  - "https_proxy={{ your_proxy_http_proxy }}"
  - "--env"
  # Без прокси: все локальные адреса, ваши домены,
  #  матрикс-контейнеры, которые могут общаться между собой по https (например Synapse <-> MAS) и все локальные адреса докера
  - "no_proxy={{ your_proxy_no_proxy }}"
  # Внутренний DNS докера
  - "--dns"
  - "127.0.0.11"


# Web-client Element
matrix_client_element_enabled: true
# Стандартный телефонный код (+7)
matrix_client_element_default_country_code: "RU"
# Темы оформления из репозитория
matrix_client_element_themes_enabled: true
matrix_client_element_themes_repository_url: "https://github.com/aaronraimist/element-themes"
# Включение сторонних тем по ссылке
matrix_client_element_setting_defaults_custom_themes_enabled: true
matrix_client_element_configuration_extension_json: |
  {
    "csp": {
      "style-src": ["'self'", "'unsafe-inline'", "https://*"],
      "img-src": ["'self'", "data:", "blob:", "https://*"],
      "connect-src": ["'self'", "https://*", "wss://*"]
    }
  }
EOF

sudo ufw allow 22/tcp
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 3478/tcp
sudo ufw allow 3478/udp
sudo ufw allow 5349/tcp
sudo ufw allow 5349/udp
sudo ufw allow 7880/tcp
sudo ufw allow 7881/tcp
sudo ufw allow 7882/udp
sudo ufw allow 8448/tcp

# Запуск установки
echo "Запускаем установку Matrix. Это займет ~30 минут..."
ansible-playbook -i inventory/hosts setup.yml --tags=install-all,start

# Регистрация администратора
ansible-playbook -i inventory/hosts setup.yml --extra-vars="username=$ADMIN_NICK password=$ADMIN_PASS admin=yes" --tags=register-user

if [[ "$NEED_XRAY" =~ ^[Yy]$ ]]; then
sudo ufw allow from 172.16.0.0/12 to any port 10808 proto tcp
sudo ufw allow from 172.16.0.0/12 to any port 10809 proto tcp
fi
sudo ufw allow 49152:49652/udp
sudo ufw --force enable

printf "\n\n\n%s\n\n" "Установка завершена!"
if [[ "$NEED_XRAY" =~ ^[Yy]$ ]]; then
  printf "Ваш XRAY-конфиг доступен по пути:\n%s\n\n" "/usr/local/etc/xray/config.json"
else
  printf "Вы отказались от установки XRAY\n\n"
fi

printf "Ваш ansible-конфиг доступен по пути:\n%s\n\n" "$HOME/matrix-docker-ansible-deploy/inventory/host_vars/$DOMAIN_MATRIX/vars.yml"
printf "Команда для повторного запуска ansible (если будете менять конфиг):\n%s\n\n" "ansible-playbook -i inventory/hosts setup.yml --tags=setup-all,start"
printf "Адрес вашего homeserver Matrix:\n%s\n\n" "$DOMAIN_MATRIX"
printf "Адрес вашего web-клиента Matrix:\n%s\n\n" "$DOMAIN_WEB_CLIENT"
printf "Адрес вашей админки Matrix:\n%s\n\n" "$DOMAIN_ADMIN_PANEL"
printf "Никнейм админа:\n%s\n\n" "$ADMIN_NICK"
printf "Пароль админа:\n%s\n\n" "$ADMIN_PASS"

unset ADMIN_NICK
unset ADMIN_PASS
