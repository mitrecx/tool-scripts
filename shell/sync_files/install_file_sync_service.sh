#!/bin/bash

# 文件同步服务安装脚本
# 用于安装和配置systemd服务

set -euo pipefail

# 配置变量
SERVICE_NAME="file-sync"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
SCRIPT_PATH=""
LOCAL_PATH=""
REMOTE_HOST=""
REMOTE_PATH=""
SSH_KEY=""
EXCLUDE_PATTERNS=()
SERVICE_USER="$USER"
SERVICE_GROUP="$(id -gn)"

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

print_info() {
    echo -e "${BLUE}[INFO]${NC} $*"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $*"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $*"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $*"
}

show_help() {
    cat << EOF
文件同步服务安装脚本

用法: $0 [选项] <脚本路径> <本地路径> <远程主机> <远程路径>

参数:
    <脚本路径>      sync_files.sh脚本的完整路径
    <本地路径>      要监听的本地目录路径
    <远程主机>      远程主机 (格式: user@host)
    <远程路径>      远程目录路径

选项:
    -k, --ssh-key <path>    SSH私钥路径
    -e, --exclude <pattern> 排除模式 (可多次指定)
    -u, --user <user>       运行服务的用户 (默认: 当前用户)
    -g, --group <group>     运行服务的用户组 (默认: 当前用户组)
    -n, --name <name>       服务名称 (默认: file-sync)
    --uninstall             卸载服务
    -h, --help              显示此帮助信息

示例:
    # 安装服务
    sudo $0 /opt/scripts/sync_files.sh /home/user/docs user@server.com /backup/docs

    # 使用SSH密钥和排除模式
    sudo $0 -k ~/.ssh/id_rsa -e "*.tmp" -e ".git" /opt/scripts/sync_files.sh /project user@server:/backup/project

    # 卸载服务
    sudo $0 --uninstall

EOF
}

# 检查权限
check_permissions() {
    if [[ $EUID -ne 0 ]]; then
        print_error "此脚本需要root权限运行"
        print_info "请使用: sudo $0 $*"
        exit 1
    fi
}

# 解析命令行参数
parse_args() {
    local uninstall=false
    
    while [[ $# -gt 0 ]]; do
        case $1 in
            -k|--ssh-key)
                SSH_KEY="$2"
                shift 2
                ;;
            -e|--exclude)
                EXCLUDE_PATTERNS+=("$2")
                shift 2
                ;;
            -u|--user)
                SERVICE_USER="$2"
                shift 2
                ;;
            -g|--group)
                SERVICE_GROUP="$2"
                shift 2
                ;;
            -n|--name)
                SERVICE_NAME="$2"
                SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
                shift 2
                ;;
            --uninstall)
                uninstall=true
                shift
                ;;
            -h|--help)
                show_help
                exit 0
                ;;
            -*)
                print_error "未知选项: $1"
                show_help
                exit 1
                ;;
            *)
                if [[ -z "$SCRIPT_PATH" ]]; then
                    SCRIPT_PATH="$1"
                elif [[ -z "$LOCAL_PATH" ]]; then
                    LOCAL_PATH="$1"
                elif [[ -z "$REMOTE_HOST" ]]; then
                    REMOTE_HOST="$1"
                elif [[ -z "$REMOTE_PATH" ]]; then
                    REMOTE_PATH="$1"
                else
                    print_error "多余的参数: $1"
                    show_help
                    exit 1
                fi
                shift
                ;;
        esac
    done
    
    if [[ "$uninstall" == "true" ]]; then
        uninstall_service
        exit 0
    fi
    
    # 验证必需参数
    if [[ -z "$SCRIPT_PATH" || -z "$LOCAL_PATH" || -z "$REMOTE_HOST" || -z "$REMOTE_PATH" ]]; then
        print_error "缺少必需参数"
        show_help
        exit 1
    fi
    
    # 验证脚本路径
    if [[ ! -f "$SCRIPT_PATH" ]]; then
        print_error "脚本文件不存在: $SCRIPT_PATH"
        exit 1
    fi
    
    if [[ ! -x "$SCRIPT_PATH" ]]; then
        print_error "脚本文件不可执行: $SCRIPT_PATH"
        print_info "请运行: chmod +x $SCRIPT_PATH"
        exit 1
    fi
    
    # 转换为绝对路径
    SCRIPT_PATH=$(realpath "$SCRIPT_PATH")
    LOCAL_PATH=$(realpath "$LOCAL_PATH")
    
    if [[ ! -d "$LOCAL_PATH" ]]; then
        print_error "本地路径不存在或不是目录: $LOCAL_PATH"
        exit 1
    fi
    
    # 验证用户和组
    if ! id "$SERVICE_USER" >/dev/null 2>&1; then
        print_error "用户不存在: $SERVICE_USER"
        exit 1
    fi
    
    if ! getent group "$SERVICE_GROUP" >/dev/null 2>&1; then
        print_error "用户组不存在: $SERVICE_GROUP"
        exit 1
    fi
}

# 生成服务文件
generate_service_file() {
    local exclude_args=""
    for pattern in "${EXCLUDE_PATTERNS[@]}"; do
        exclude_args+=" -e '$pattern'"
    done
    
    local ssh_key_arg=""
    if [[ -n "$SSH_KEY" ]]; then
        ssh_key_arg=" -k '$SSH_KEY'"
    fi
    
    local user_home
    # user_home=$(eval echo "~$SERVICE_USER")
    user_home=/home/josie/test/claude
    
    cat > "$SERVICE_FILE" << EOF
[Unit]
Description=Real-time File Synchronization Service
Documentation=File sync service for real-time directory synchronization
After=network.target network-online.target
Wants=network-online.target
Requires=network.target

[Service]
Type=simple
User=$SERVICE_USER
Group=$SERVICE_GROUP
WorkingDirectory=$user_home
Environment=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
Environment=HOME=$user_home

ExecStart=$SCRIPT_PATH$ssh_key_arg$exclude_args '$LOCAL_PATH' '$REMOTE_HOST' '$REMOTE_PATH'

# 服务管理
Restart=always
RestartSec=10
StartLimitInterval=300
StartLimitBurst=5

# 资源限制
LimitNOFILE=65536
LimitNPROC=4096

# 日志配置
StandardOutput=journal
StandardError=journal
SyslogIdentifier=$SERVICE_NAME

# 安全配置
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=read-only
ReadWritePaths=$LOCAL_PATH $user_home /var/log /tmp

[Install]
WantedBy=multi-user.target
EOF
}

# 安装服务
install_service() {
    print_info "正在安装文件同步服务..."
    
    # 停止现有服务（如果存在）
    if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
        print_info "停止现有服务..."
        systemctl stop "$SERVICE_NAME"
    fi
    
    # 生成服务文件
    generate_service_file
    print_success "服务文件已创建: $SERVICE_FILE"
    
    # 重载systemd配置
    systemctl daemon-reload
    print_info "已重载systemd配置"
    
    # 启用服务
    systemctl enable "$SERVICE_NAME"
    print_success "服务已设置为开机自启"
    
    # 启动服务
    if systemctl start "$SERVICE_NAME"; then
        print_success "服务启动成功"
    else
        print_error "服务启动失败"
        print_info "查看服务状态: systemctl status $SERVICE_NAME"
        print_info "查看日志: journalctl -u $SERVICE_NAME -f"
        exit 1
    fi
    
    # 显示服务状态
    echo
    print_info "服务状态:"
    systemctl status "$SERVICE_NAME" --no-pager -l
    
    echo
    print_success "文件同步服务安装完成！"
    print_info "常用命令:"
    print_info "  查看状态: systemctl status $SERVICE_NAME"
    print_info "  查看日志: journalctl -u $SERVICE_NAME -f"
    print_info "  停止服务: systemctl stop $SERVICE_NAME"
    print_info "  启动服务: systemctl start $SERVICE_NAME"
    print_info "  重启服务: systemctl restart $SERVICE_NAME"
    print_info "  禁用服务: systemctl disable $SERVICE_NAME"
}

# 卸载服务
uninstall_service() {
    print_info "正在卸载文件同步服务..."
    
    # 停止服务
    if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
        print_info "停止服务..."
        systemctl stop "$SERVICE_NAME"
    fi
    
    # 禁用服务
    if systemctl is-enabled --quiet "$SERVICE_NAME" 2>/dev/null; then
        print_info "禁用服务..."
        systemctl disable "$SERVICE_NAME"
    fi
    
    # 删除服务文件
    if [[ -f "$SERVICE_FILE" ]]; then
        rm -f "$SERVICE_FILE"
        print_success "已删除服务文件: $SERVICE_FILE"
    fi
    
    # 重载systemd配置
    systemctl daemon-reload
    print_info "已重载systemd配置"
    
    print_success "文件同步服务卸载完成！"
}

# 主函数
main() {
    print_info "文件同步服务安装程序"
    
    # 检查权限
    check_permissions "$@"
    
    # 解析参数
    parse_args "$@"
    
    # 安装服务
    install_service
}

# 执行主函数
main "$@"