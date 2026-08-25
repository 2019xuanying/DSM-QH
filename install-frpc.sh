#!/usr/bin/env bash

# ==================================================
# FRP 客户端全功能管理脚本
#
# 一键运行:
# bash <(curl -fsSL https://hub.20250225.ggff.net/frp/install-frpc.sh)
#
# 支持:
# Ubuntu Debian CentOS Alpine OpenWRT 群晖 DSM
#
# 支持架构:
# amd64 x86 arm64 arm armv5 mips
#
# 支持协议:
# TCP UDP HTTP HTTPS STCP XTCP SUDP TCPMUX
#
# 功能:
# - 自动安装/升级 FRP
# - 多端口映射
# - TCP/UDP/HTTP/HTTPS
# - 修改协议
# - 修改端口
# - 修改备注
# - 自动随机端口
# - SSH 快速连接
# - DSM/OpenWRT 自启动
# ==================================================

set -e

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

FRP_SERVER="frp.20250225.ggff.net"
FRP_PORT="3000"
FRP_TOKEN="bK9uQ3xW1kJ9gY1oI7rU2jE7kV8zD9eH"

INSTALL_DIR="/usr/local/frp"
CONFIG_FILE="${INSTALL_DIR}/frpc.toml"

# ==================================================
# 重启
# ==================================================

restart_frpc() {

    if command -v systemctl >/dev/null 2>&1; then

        systemctl restart frpc

    elif [ -f "/usr/local/etc/rc.d/frpc.sh" ]; then

        /usr/local/etc/rc.d/frpc.sh restart

    else

        killall frpc >/dev/null 2>&1 || true

        nohup ${INSTALL_DIR}/frpc -c ${CONFIG_FILE} >/dev/null 2>&1 &

    fi

    echo -e "${GREEN}FRP 已重启${NC}"
}

# ==================================================
# 停止
# ==================================================

stop_frpc() {

    if command -v systemctl >/dev/null 2>&1; then
        systemctl stop frpc >/dev/null 2>&1 || true
    fi

    killall frpc >/dev/null 2>&1 || true

    echo -e "${YELLOW}FRP 已停止${NC}"
}

# ==================================================
# 查看映射
# ==================================================

show_config() {

    if [ ! -f "${CONFIG_FILE}" ]; then
        echo -e "${RED}FRP 未安装${NC}"
        return
    fi

    echo
    echo "================ 当前映射 ================"

    awk '
    /^\[\[proxies\]\]/{
        if(n>0) print "----------------------------------------"
        n++
    }
    {
        print
    }
    ' ${CONFIG_FILE}

    echo "=========================================="
}

# ==================================================
# 添加映射
# ==================================================

add_proxy() {

    echo
    echo "支持协议:"
    echo "1. TCP"
    echo "2. UDP"
    echo "3. HTTP"
    echo "4. HTTPS"
    echo "5. STCP"
    echo "6. XTCP"
    echo "7. SUDP"
    echo "8. TCPMUX"
    echo

    printf "请选择协议: "
    read PROTOCOL_NUM

    case "$PROTOCOL_NUM" in
        1) PROTOCOL="tcp" ;;
        2) PROTOCOL="udp" ;;
        3) PROTOCOL="http" ;;
        4) PROTOCOL="https" ;;
        5) PROTOCOL="stcp" ;;
        6) PROTOCOL="xtcp" ;;
        7) PROTOCOL="sudp" ;;
        8) PROTOCOL="tcpmux" ;;
        *)
            echo -e "${RED}协议错误${NC}"
            return
            ;;
    esac

    echo

    printf "请输入本地 IP(默认127.0.0.1): "
    read LOCAL_IP

    [ -z "$LOCAL_IP" ] && LOCAL_IP="127.0.0.1"

    printf "请输入本地端口: "
    read LOCAL_PORT

    [ -z "$LOCAL_PORT" ] && {
        echo -e "${RED}本地端口不能为空${NC}"
        return
    }

    # HTTP HTTPS
    if [ "$PROTOCOL" = "http" ] || \
       [ "$PROTOCOL" = "https" ]; then

        printf "请输入域名: "
        read CUSTOM_DOMAIN

        [ -z "$CUSTOM_DOMAIN" ] && {
            echo -e "${RED}域名不能为空${NC}"
            return
        }

    # TCPMUX
    elif [ "$PROTOCOL" = "tcpmux" ]; then

        printf "请输入 tcpmux 域名: "
        read CUSTOM_DOMAIN

        printf "请输入 HTTP 用户名: "
        read HTTP_USER

        printf "请输入 HTTP 密码: "
        read HTTP_PASS

    # STCP XTCP SUDP
    elif [ "$PROTOCOL" = "stcp" ] || \
         [ "$PROTOCOL" = "xtcp" ] || \
         [ "$PROTOCOL" = "sudp" ]; then

        printf "请输入 secretKey(默认123456): "
        read SECRET_KEY

        [ -z "$SECRET_KEY" ] && SECRET_KEY="123456"

    # TCP UDP
    else

        printf "请输入外部端口(直接回车随机): "
        read REMOTE_PORT

        [ -z "$REMOTE_PORT" ] && \
            REMOTE_PORT=$((RANDOM % 10000 + 20000))

    fi

    printf "请输入节点备注(直接回车默认): "
    read CUSTOM_NAME

    if [ -z "$CUSTOM_NAME" ]; then

        if [ "$PROTOCOL" = "tcp" ] && [ "$LOCAL_PORT" = "22" ]; then
            CUSTOM_NAME="ssh-${REMOTE_PORT}"
        else
            CUSTOM_NAME="${PROTOCOL}-${LOCAL_PORT}"
        fi
    fi

    {
        echo
        echo "[[proxies]]"
        echo "name = \"${CUSTOM_NAME}\""
        echo "type = \"${PROTOCOL}\""
        echo "localIP = \"${LOCAL_IP}\""
        echo "localPort = ${LOCAL_PORT}"

        # HTTP HTTPS
        if [ "$PROTOCOL" = "http" ] || \
           [ "$PROTOCOL" = "https" ]; then

            echo "customDomains = [\"${CUSTOM_DOMAIN}\"]"

        # TCPMUX
        elif [ "$PROTOCOL" = "tcpmux" ]; then

            echo "multiplexer = \"httpconnect\""
            echo "customDomains = [\"${CUSTOM_DOMAIN}\"]"

            [ -n "$HTTP_USER" ] && \
                echo "httpUser = \"${HTTP_USER}\""

            [ -n "$HTTP_PASS" ] && \
                echo "httpPassword = \"${HTTP_PASS}\""

        # STCP XTCP SUDP
        elif [ "$PROTOCOL" = "stcp" ] || \
             [ "$PROTOCOL" = "xtcp" ] || \
             [ "$PROTOCOL" = "sudp" ]; then

            echo "secretKey = \"${SECRET_KEY}\""

        # TCP UDP
        else

            echo "remotePort = ${REMOTE_PORT}"

        fi

    } >> ${CONFIG_FILE}

    echo
    echo -e "${GREEN}映射添加完成${NC}"

    # SSH 显示连接命令
    if [ "$PROTOCOL" = "tcp" ] && [ "$LOCAL_PORT" = "22" ]; then

        echo
        echo -e "${GREEN}SSH 连接命令:${NC}"
        echo "ssh root@${FRP_SERVER} -p ${REMOTE_PORT}"
        echo
    fi

    restart_frpc
}

# ==================================================
# 修改备注
# ==================================================

change_name() {

    grep "name =" ${CONFIG_FILE} | nl

    echo
    printf "请选择映射编号: "
    read NUM

    OLD_NAME=$(grep "name =" ${CONFIG_FILE} | sed -n "${NUM}p" | cut -d '"' -f2)

    printf "请输入新的备注: "
    read NEW_NAME

    [ -z "$NEW_NAME" ] && return

    sed -i "s/name = \"${OLD_NAME}\"/name = \"${NEW_NAME}\"/" ${CONFIG_FILE}

    restart_frpc

    echo -e "${GREEN}备注修改完成${NC}"
}

# ==================================================
# 修改本地端口
# ==================================================

change_local_port() {

    grep "name =" ${CONFIG_FILE} | nl

    echo
    printf "请选择映射编号: "
    read NUM

    PROXY_NAME=$(grep "name =" ${CONFIG_FILE} | sed -n "${NUM}p" | cut -d '"' -f2)

    printf "请输入新的本地端口: "
    read LOCAL_PORT

    awk -v name="$PROXY_NAME" -v port="$LOCAL_PORT" '
    BEGIN{f=0}
    /^\[\[proxies\]\]/{if(f)f=0}
    {
        if($0 ~ "name = \""name"\""){f=1}
        if(f && $0 ~ /^localPort = /){
            print "localPort = "port
            next
        }
        print
    }' ${CONFIG_FILE} > ${CONFIG_FILE}.tmp

    mv ${CONFIG_FILE}.tmp ${CONFIG_FILE}

    restart_frpc

    echo -e "${GREEN}本地端口修改完成${NC}"
}

# ==================================================
# 修改外部端口
# ==================================================

change_remote_port() {

    grep "name =" ${CONFIG_FILE} | nl

    echo
    printf "请选择映射编号: "
    read NUM

    PROXY_NAME=$(grep "name =" ${CONFIG_FILE} | sed -n "${NUM}p" | cut -d '"' -f2)

    printf "请输入新的外部端口: "
    read NEW_PORT

    awk -v name="$PROXY_NAME" -v port="$NEW_PORT" '
    BEGIN{f=0}
    /^\[\[proxies\]\]/{if(f)f=0}
    {
        if($0 ~ "name = \""name"\""){f=1}
        if(f && $0 ~ /^remotePort = /){
            print "remotePort = "port
            next
        }
        print
    }' ${CONFIG_FILE} > ${CONFIG_FILE}.tmp

    mv ${CONFIG_FILE}.tmp ${CONFIG_FILE}

    echo
    echo -e "${GREEN}新的 SSH 命令:${NC}"
    echo "ssh root@${FRP_SERVER} -p ${NEW_PORT}"

    echo
    echo -e "${YELLOW}5 秒后自动重启 FRP${NC}"

    (
        sleep 5
        restart_frpc
    ) >/dev/null 2>&1 &
}

# ==================================================
# 卸载
# ==================================================

uninstall_frpc() {

    stop_frpc

    rm -rf ${INSTALL_DIR}
    rm -f /etc/systemd/system/frpc.service
    rm -f /usr/local/etc/rc.d/frpc.sh
    rm -f /etc/init.d/frpc

    echo -e "${GREEN}FRP 已卸载${NC}"
}

# ==================================================
# 安装 FRP
# ==================================================

install_frp() {

    ARCH=$(uname -m)

    case "$ARCH" in
        x86_64|amd64) FRP_ARCH="amd64" ;;
        i386|i686) FRP_ARCH="386" ;;
        aarch64|arm64) FRP_ARCH="arm64" ;;
        armv7l|armv7) FRP_ARCH="arm" ;;
        armv5*|armv6*) FRP_ARCH="arm" ;;
        mips|mipsel) FRP_ARCH="mips" ;;
        *)
            echo -e "${RED}不支持架构:${NC} $ARCH"
            exit 1
            ;;
    esac

    echo -e "${GREEN}系统架构:${NC} $ARCH -> $FRP_ARCH"

    LATEST_VERSION=$(curl -s \
    https://api.github.com/repos/fatedier/frp/releases/latest \
    | grep tag_name | cut -d '"' -f4)

    echo -e "${GREEN}FRP 最新版本:${NC} ${LATEST_VERSION}"

    FRP_FILE="frp_${LATEST_VERSION#v}_linux_${FRP_ARCH}.tar.gz"

    DOWNLOAD_URL="https://github.com/fatedier/frp/releases/download/${LATEST_VERSION}/${FRP_FILE}"
    mkdir -p /tmp/frp-install
    cd /tmp/frp-install

    echo -e "${YELLOW}正在下载 FRP...${NC}"

    if command -v curl >/dev/null 2>&1; then
        curl -L -o frp.tar.gz "$DOWNLOAD_URL"
    else
        wget -O frp.tar.gz "$DOWNLOAD_URL"
    fi

    echo -e "${YELLOW}正在解压...${NC}"

    tar -zxf frp.tar.gz

    FRP_DIR=$(find . -maxdepth 1 -type d -name "frp_*" | head -n 1)

    mkdir -p ${INSTALL_DIR}

    stop_frpc

    rm -f ${INSTALL_DIR}/frpc

    cp ${FRP_DIR}/frpc ${INSTALL_DIR}/
    chmod +x ${INSTALL_DIR}/frpc

cat > ${CONFIG_FILE} <<EOF
serverAddr = "${FRP_SERVER}"
serverPort = ${FRP_PORT}

auth.method = "token"
auth.token = "${FRP_TOKEN}"
EOF

    # systemd
    if command -v systemctl >/dev/null 2>&1; then

cat > /etc/systemd/system/frpc.service <<EOF
[Unit]
Description=FRP Client
After=network.target

[Service]
Type=simple
ExecStart=${INSTALL_DIR}/frpc -c ${CONFIG_FILE}
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

        systemctl daemon-reload
        systemctl enable frpc >/dev/null 2>&1

    # 群晖 DSM
    elif [ -d "/usr/local/etc/rc.d" ]; then

cat > /usr/local/etc/rc.d/frpc.sh <<EOF
#!/bin/sh

case \$1 in
start)
${INSTALL_DIR}/frpc -c ${CONFIG_FILE} >/dev/null 2>&1 &
;;
stop)
killall frpc >/dev/null 2>&1
;;
restart)
killall frpc >/dev/null 2>&1
sleep 1
${INSTALL_DIR}/frpc -c ${CONFIG_FILE} >/dev/null 2>&1 &
;;
esac
EOF

        chmod +x /usr/local/etc/rc.d/frpc.sh

    fi

    echo
    echo -e "${GREEN}FRP 安装完成${NC}"

    add_proxy
}

# ==================================================
# 主菜单
# ==================================================

while true
do

clear

echo "=============================="
echo " FRP 管理菜单"
echo "=============================="
echo
echo "1. 安装/升级 FRP"
echo "2. 添加新映射"
echo "3. 修改备注"
echo "4. 修改本地端口"
echo "5. 修改外部端口"
echo "6. 查看当前映射"
echo "7. 重启 FRP"
echo "8. 停止 FRP"
echo "9. 卸载 FRP"
echo "0. 退出"
echo

printf "请输入选项: "
read MENU

case "$MENU" in

1)
    install_frp
    ;;

2)
    add_proxy
    ;;

3)
    change_name
    ;;

4)
    change_local_port
    ;;

5)
    change_remote_port
    ;;

6)
    show_config
    ;;

7)
    restart_frpc
    ;;

8)
    stop_frpc
    ;;

9)
    uninstall_frpc
    ;;

0)
    exit
    ;;

*)
    echo -e "${RED}输入错误${NC}"
    ;;
esac

echo
read -p "按回车继续..."

done