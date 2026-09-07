#!/usr/bin/env bash
# https://github.com/GeorgianaBlake/AnyTLS
# AnyTLS一键管理脚本 (群晖 DSM 7.x 适配版)
# 修复：依赖检测替换为群晖原生环境、移除禁用防火墙逻辑、更换随机数生成方式、修复原脚本更新时的 darwin 包下载 Bug。

set -euo pipefail

# 适配群晖：将配置放到 /usr/local/etc 防止大版本更新被重置
CONFIG_DIR="/usr/local/etc/AnyTLS"
ANYTLS_SNAP_DIR="/tmp/anytls_install_$$"
ANYTLS_SERVER="${CONFIG_DIR}/server"
ANYTLS_SERVICE_NAME="anytls.service"
ANYTLS_SERVICE_FILE="/etc/systemd/system/${ANYTLS_SERVICE_NAME}"
ANYTLS_CONFIG_FILE="${CONFIG_DIR}/config.yaml"
TZ_DEFAULT="Asia/Shanghai"
SHELL_VERSION="0.1.0-Synology"
ANYTLS_VERSION="0.0.8"
AT_ALIASES="AT_Synology"

Font="\033[0m"
Red="\033[31m"
Green="\033[32m"
Yellow="\033[33m"
Blue="\033[34m"
Magenta="\033[35m"
Cyan="\033[36m"
RedBG="\033[41m"
BGreen="\033[92m"
BYellow="\033[93m"
BRed="\033[91m"

OK="${Green}[OK]${Font}"
ERROR="${Red}[ERROR]${Font}"
WARN="${Yellow}[WARN]${Font}"
INFO="${Cyan}[INFO]${Font}"

print_ok() { echo -e "${OK}${Blue} $1 ${Font}"; }
print_info() { echo -e "${INFO}${Cyan} $1 ${Font}"; }
print_error() { echo -e "${ERROR} ${RedBG} $1 ${Font}"; }

judge() {
  if [[ 0 -eq $? ]]; then
    print_ok "$1 完成"
    sleep 1
  else
    print_error "$1 失败"
    exit 1
  fi
}

trap 'echo -e "\n${WARN} 已中断"; exit 1' INT

ensure_root() {
  if [[ $EUID -ne 0 ]]; then
    clear
    echo "Error: 必须使用 root 运行本脚本 (群晖请先运行 sudo -i)!" 1>&2
    exit 1
  fi
}

has_cmd() { command -v "$1" >/dev/null 2>&1; }

get_arch() {
  local arch_raw
  arch_raw=$(uname -m)
  case "$arch_raw" in
    x86_64 | amd64) echo "amd64" ;;
    aarch64 | arm64) echo "arm64" ;;
    *)
      print_error "不支持的系统架构 ($arch_raw)" >&2
      return 1
      ;;
  esac
}

# 适配群晖：直接检查内置环境，不调用 apt/yum
os_install() {
  if ! has_cmd curl || ! has_cmd unzip; then
    print_error "系统缺少 curl 或 unzip，请确保群晖系统环境完整！"
    exit 1
  else
    print_ok "环境依赖检查通过 (内置 curl, unzip)"
  fi
}

pause() { read -rp "按回车返回菜单..." _; }
quit() { exit 0; }
hr() { printf '%*s\n' 40 '' | tr ' ' '='; }

# 适配群晖：只提示，不调用 systemctl 去停火墙，因为群晖防火墙由 DSM 控制面板管理
close_wall() {
  print_info "【重要提示】请务必前往群晖 DSM 控制面板 -> 安全性 -> 防火墙，放行您稍后配置的 AnyTLS 端口！"
  sleep 2
}

urlencode() {
  local s="$1"
  local i c
  for (( i=0; i<${#s}; i++ )); do
    c=${s:$i:1}
    case "$c" in
      [a-zA-Z0-9.~_-]) printf '%s' "$c" ;;
      *) printf '%%%02X' "'$c" ;;
    esac
  done
}

# 适配群晖：替换 shuf 为 awk 生成随机端口
random_port() { awk -v min=2000 -v max=65000 'BEGIN{srand(); print int(min+rand()*(max-min+1))}'; }

# 适配群晖：增加备用的 UUID 生成方式
gen_password() { 
  if [ -f /proc/sys/kernel/random/uuid ]; then
    cat /proc/sys/kernel/random/uuid
  else
    cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 16 | head -n 1
  fi
}

valid_port() {
  local p="${1:-}"
  [[ "$p" =~ ^[0-9]+$ ]] && (( p >= 1 && p <= 65535 ))
}

is_port_used() {
  local port="$1"
  if has_cmd ss; then
    ss -tuln | awk '{print $5}' | grep -Eq "[:.]${port}([[:space:]]|$)"
  elif has_cmd netstat; then
    netstat -tuln 2>/dev/null | awk '{print $4}' | grep -Eq "[:.]${port}$"
  else
    return 1
  fi
}

read_port_interactive() {
  local input
  while true; do
    read -t 15 -p "回车或等待15秒为随机端口，或者自定义端口请输入(1-65535)：" input || true
    if [[ -z "${input:-}" ]]; then
      input=$(random_port)
    fi
    if ! valid_port "$input"; then
      echo "端口不合法：$input，请输入一个有效的端口（1-65535）。"
      continue
    fi
    if is_port_used "$input"; then
      echo "端口 $input 已被占用，请选择另一个端口。"
      continue
    fi
    echo "$input"
    break
  done
}

get_ip() {
  local ip4 ip6
  ip4=$(curl -s -4 http://www.cloudflare.com/cdn-cgi/trace | awk -F= '/^ip=/{print $2}')
  if [[ -n "${ip4}" ]]; then echo "${ip4}"; return; fi
  ip6=$(curl -s -6 http://www.cloudflare.com/cdn-cgi/trace | awk -F= '/^ip=/{print $2}')
  if [[ -n "${ip6}" ]]; then echo "${ip6}"; return; fi
  curl -s https://api.ipify.org || true
}

get_latest_version() {
  local version
  version=$(curl -s https://api.github.com/repos/anytls/anytls-go/releases/latest \
    | grep '"tag_name":' \
    | sed -E 's/.*"([^"]+)".*/\1/')
  if [[ -z "$version" ]]; then
    print_error "无法获取AnyTLS最新版本号，请检查网络或GitHub API限制" >&2
    return 1
  fi
  echo "$version"
}

get_install_version() {
  if [[ -f "$ANYTLS_SERVICE_FILE" ]]; then
    grep '^X-AT-Version=' "$ANYTLS_SERVICE_FILE" | sed -E 's/^X-AT-Version=//'
  else
    echo "unknown"
  fi
}

write_systemd() {
  local version port pass
  port="$2"
  pass="$3"
  if [[ ${1-} =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    version="$1"
  else
    version="$(get_install_version)"
  fi
  cat > "$ANYTLS_SERVICE_FILE" << EOF
[Unit]
Description=AnyTLS Server Service
Documentation=https://github.com/anytls/anytls-go
After=network.target network-online.target
Wants=network-online.target
X-AT-Version=${version}

[Service]
Type=simple
User=root
Environment=TZ=${TZ_DEFAULT}
ExecStart="${ANYTLS_SERVER}" -l 0.0.0.0:${port} -p "${pass}"
Restart=on-failure
RestartSec=10s
LimitNOFILE=65535
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
}

write_config() {
  local port="$1" pass="$2"
  mkdir -p "$(dirname "${ANYTLS_CONFIG_FILE}")"
  cat > "${ANYTLS_CONFIG_FILE}" <<EOF
listen: :${port}
auth:
  type: password
  password: ${pass}
EOF
}

client_export() {
  if [[ ! -f "${ANYTLS_CONFIG_FILE}" ]]; then
    print_error "未找到 ${ANYTLS_CONFIG_FILE}"
    return 1
  fi
  local port pass ip link
  port=$(sed -nE 's/^[[:space:]]*listen:[[:space:]]*.*:([0-9]+)[[:space:]]*$/\1/p' "${ANYTLS_CONFIG_FILE}")
  if [[ -z "${port}" ]]; then
    port=$(awk '/^[[:space:]]*listen:/ { if (match($0, /:([0-9]+)[[:space:]]*$/, a)) print a[1] }' "${ANYTLS_CONFIG_FILE}")
  fi
  pass=$(sed -nE 's/^[[:space:]]*password:[[:space:]]*(.*)$/\1/p' "${ANYTLS_CONFIG_FILE}")
  ip=$(get_ip)
  local alias_enc
  alias_enc=$(urlencode "${AT_ALIASES}")
  link="${pass}@${ip}:${port}/?insecure=1#${alias_enc}"

  echo -e "=========== AnyTLS 配置参数 ==========="
  echo -e " 代理模式: AnyTLS"
  echo -e " 地址: ${ip}"
  echo -e " 端口: ${port}"
  echo -e " 密码: ${pass}"
  echo -e " 传输协议: tls"
  echo -e " 跳过证书验证: true"
  echo -e " 备注: AnyTLS 使用自签名证书, 客户端需启用 '允许不安全' 或 '跳过证书验证'"
  echo -e "========================================="
  echo -e " URL链接(可复制导入):"
  echo -e " anytls://${link}"
  echo -e "========================================="
}

start_service() { print_info "正在启动 AnyTLS 服务..."; systemctl start "${ANYTLS_SERVICE_NAME}"; sleep 1; status_service; }
stop_service() { print_info "正在停止 AnyTLS 服务..."; systemctl stop "${ANYTLS_SERVICE_NAME}"; sleep 1; status_service; }
status_service() { print_info "AnyTLS 服务状态:"; systemctl status "${ANYTLS_SERVICE_NAME}" --no-pager; }
log_service() { print_info "显示 AnyTLS 服务日志 (按 Ctrl+C 退出):"; journalctl -u "${ANYTLS_SERVICE_NAME}" -f "$@"; }

binary_exists() { [[ -x "${ANYTLS_SERVER}" ]]; }
service_file_exists() { systemctl cat "${ANYTLS_SERVICE_NAME}" >/dev/null 2>&1 || [[ -f "${ANYTLS_SERVICE_FILE}" ]]; }
is_installed() { binary_exists || service_file_exists; }
is_active() { systemctl is-active "${ANYTLS_SERVICE_NAME}" >/dev/null 2>&1; }

install_status_text() {
  if is_installed; then
    if is_active; then
      echo -e "${BGreen}已安装（运行中）${Font}"
    else
      if systemctl is-failed "${ANYTLS_SERVICE_NAME}" >/dev/null 2>&1; then
        echo -e "${BYellow}已安装（已停止，上次启动失败）${Font}"
      else
        echo -e "${BYellow}已安装（已停止）${Font}"
      fi
    fi
  else
    echo -e "${BRed}未安装${Font}"
  fi
}

restart_service() {
  systemctl daemon-reload || true
  systemctl enable "${ANYTLS_SERVICE_NAME}" || true
  systemctl restart "${ANYTLS_SERVICE_NAME}"
  systemctl status --no-pager "${ANYTLS_SERVICE_NAME}" | sed -n '1,6p' || true
}

install_anytls() {
  mkdir -p "$CONFIG_DIR"
  print_info "正在检查环境..."
  os_install
  judge "环境依赖检测"
  
  print_info "正在检查防火墙配置..."
  close_wall
  
  print_info "正在检测系统架构..."
  ARCH=$(get_arch) || exit 1
  echo -e "${INFO} 检测到系统架构: ${Green}${ARCH}${Font}"
  
  LATEST=$(get_latest_version) || exit 1
  sleep 1
  print_info "正在下载AnyTLS..."
  AT_URL="https://github.com/anytls/anytls-go/releases/download/${LATEST}/anytls_${LATEST#v}_linux_${ARCH}.zip"
  print_info "AnyTLS最新版本 ${LATEST}"
  
  mkdir -p "$ANYTLS_SNAP_DIR"
  FILENAME="anytls_${LATEST#v}_linux_${ARCH}.zip"
  OUTPUT_PATH="${ANYTLS_SNAP_DIR}/${FILENAME}"
  
  curl -L -o "$OUTPUT_PATH" "$AT_URL"
  if [ $? -ne 0 ]; then
    print_error "下载失败AnyTLS" >&2
    exit 1
  fi
  judge "下载AnyTLS"
  
  unzip -o "$OUTPUT_PATH" -d "$ANYTLS_SNAP_DIR"
  mv "${ANYTLS_SNAP_DIR}/anytls-server" "$ANYTLS_SERVER"
  rm -rf "${ANYTLS_SNAP_DIR}"
  chmod +x "$ANYTLS_SERVER"
  
  print_info "正在创建/更新 systemd 服务文件: ${ANYTLS_SERVER} ..."
  local port pass
  port=$(read_port_interactive)
  pass=$(gen_password)
  
  write_systemd "$LATEST" "$port" "$pass"
  write_config "$port" "$pass"
  systemctl daemon-reload
  
  if ! systemctl enable "${ANYTLS_SERVICE_NAME}"; then
    print_info "设置开机自启失败"
    exit 1
  fi
  if ! systemctl restart "${ANYTLS_SERVICE_NAME}"; then
    print_error "启动/重启 AnyTLS 服务失败。请检查日志"
    exit 1
  fi
  
  sleep 2
  if systemctl is-active --quiet "${ANYTLS_SERVICE_NAME}"; then
    print_ok "AnyTLS 服务已成功启动"
    echo -e "${OK} 安装完成，以下为客户端导入参数："
    client_export
    echo
    exit 0
  else
    echo "错误: AnyTLS 服务未能成功启动。"; status_service; log_service -n 20;
  fi
}

update_anytls() {
  if ! is_installed; then
    print_error "您还未安装 AnyTLS, 无法更新"
    exit 1
  fi
  print_info "正在检测系统架构..."
  ARCH=$(get_arch) || exit 1
  echo -e "${INFO} 检测到系统架构: ${Green}${ARCH}${Font}"
  
  LATEST=$(get_latest_version) || exit 1
  sleep 1
  print_info "正在下载AnyTLS..."
  AT_URL="https://github.com/anytls/anytls-go/releases/download/${LATEST}/anytls_${LATEST#v}_linux_${ARCH}.zip"
  print_info "AnyTLS最新版本 ${LATEST}"
  
  mkdir -p "$ANYTLS_SNAP_DIR"
  # 【Bug 修复】修复了原脚本此处错误写死为 darwin 的问题，替换为了 linux
  FILENAME="anytls_${LATEST#v}_linux_${ARCH}.zip"
  OUTPUT_PATH="${ANYTLS_SNAP_DIR}/${FILENAME}"
  
  curl -L -o "$OUTPUT_PATH" "$AT_URL"
  if [ $? -ne 0 ]; then
    print_error "下载失败AnyTLS" >&2
    exit 1
  fi
  judge "下载AnyTLS"
  
  unzip -o "$OUTPUT_PATH" -d "$ANYTLS_SNAP_DIR"
  mv "${ANYTLS_SNAP_DIR}/anytls-server" "$ANYTLS_SERVER"
  rm -rf "${ANYTLS_SNAP_DIR}"
  chmod +x "$ANYTLS_SERVER"
  
  print_info "正在创建/更新 systemd 服务文件: ${ANYTLS_SERVER} ..."
  local port pass
  port=$(sed -nE 's/^[[:space:]]*listen:[[:space:]]*.*:([0-9]+)[[:space:]]*$/\1/p' "${ANYTLS_CONFIG_FILE}")
  pass=$(sed -nE 's/^[[:space:]]*password:[[:space:]]*(.*)$/\1/p' "${ANYTLS_CONFIG_FILE}")
  
  [[ -z "$port" ]] && port=$(random_port)
  [[ -z "$pass" ]] && pass=$(gen_password)
  
  write_systemd "$LATEST" "$port" "$pass"
  write_config "$port" "$pass"
  systemctl daemon-reload
  
  if ! systemctl enable "${ANYTLS_SERVICE_NAME}"; then
    print_info "设置开机自启失败"
    exit 1
  fi
  if ! systemctl restart "${ANYTLS_SERVICE_NAME}"; then
    print_error "启动/重启 AnyTLS 服务失败。请检查日志"
    exit 1
  fi
  
  sleep 2
  if systemctl is-active --quiet "${ANYTLS_SERVICE_NAME}"; then
    print_ok "AnyTLS 服务已成功启动"
    echo -e "${OK} 更新完成，以下为客户端导入参数："
    client_export
    echo
    exit 0
  else
    echo "错误: AnyTLS 服务未能成功启动。"; status_service; log_service -n 20;
  fi
}

uninstall_anytls() {
  if ! is_installed; then
    print_error "您还未安装 AnyTLS, 无法卸载"
    exit 1
  fi
  read -p "确认卸载并删除配置？(y/N): " ans
  if [[ "${ans:-N}" != [yY] ]]; then
    echo "已取消"
    return
  fi
  systemctl stop "${ANYTLS_SERVICE_NAME}" || true
  systemctl disable "${ANYTLS_SERVICE_NAME}" || true
  rm -f /etc/systemd/system/${ANYTLS_SERVICE_NAME} || true
  systemctl daemon-reload || true
  rm -rf "${CONFIG_DIR}" || true
  echo -e "${OK} 卸载完成。"
}

view_config() {
  if ! is_installed; then
    print_error "您还未安装 AnyTLS, 无法查看配置"
    exit 1
  fi
  echo
  echo -e "以下为客户端导入参数："
  client_export
  echo
  exit 0
}

set_port() {
  if ! is_installed; then
    print_error "您还未安装 AnyTLS, 无法设置端口"
    exit 1
  fi
  local new_port
  new_port=$(read_port_interactive)
  local pass
  pass=$(sed -nE 's/^[[:space:]]*password:[[:space:]]*(.*)$/\1/p' "${ANYTLS_CONFIG_FILE}")
  write_systemd "" "$new_port" "$pass"
  write_config "$new_port" "$pass"
  restart_service
  clear
  echo -e "${OK} 端口已更新为：${new_port}"
  echo
  echo -e "${INFO} 当前客户端导入参数："
  echo
  client_export
  echo
  exit 0
}

set_password() {
  if ! is_installed; then
    print_error "您还未安装 AnyTLS, 无法设置端口"
    exit 1
  fi
  local new_pass
  new_pass=$(gen_password)
  local port
  port=$(sed -nE 's/^[[:space:]]*listen:[[:space:]]*.*:([0-9]+)[[:space:]]*$/\1/p' "${ANYTLS_CONFIG_FILE}")
  write_systemd "" "$port" "$new_pass"
  write_config "$port" "$new_pass"
  restart_service
  clear
  echo -e "${OK} 密码已更新为：${new_pass}"
  echo
  echo -e "${INFO} 当前客户端导入参数："
  echo
  client_export
  echo
  exit 0
}

echo_version() {
  if ! is_installed; then
    return 0
  fi
  echo -e " 当前AnyTLS版本: $(get_install_version)"
}

main() {
  while true; do
    clear
    hr
    echo -e " AnyTLS 群晖 DSM 一键脚本"
    echo -e " 适配: 取消系统防火墙依赖, 修复更新 Bug, 调整持久化目录"
    echo -e " 当前脚本版本: ${Magenta}${SHELL_VERSION}${Font}"
    echo -e " 安装状态：$(install_status_text)"
    echo_version
    hr
    echo -e "${Cyan}1. 安装/重装 AnyTLS${Font}"
    echo -e "${Cyan}2. 更新 AnyTLS${Font}"
    echo -e "${Cyan}3. 查看配置${Font}"
    echo -e "${Cyan}4. 卸载 AnyTLS${Font}"
    echo -e "${Cyan}5. 更改端口${Font}"
    echo -e "${Cyan}6. 更改密码${Font}"
    echo -e "${Cyan}0. 退出${Font}"
    hr
      read -p "请输入数字 [0-6]: " choice
    case "${choice}" in
      1) install_anytls; quit ;;
      2) update_anytls; quit ;;
      3) view_config; quit ;;
      4) uninstall_anytls; quit ;;
      5) set_port; quit ;;
      6) set_password; quit ;;
      0) exit 0 ;;
      *) echo "无效选项"; pause ;;
    esac
  done
}

ensure_root
main
