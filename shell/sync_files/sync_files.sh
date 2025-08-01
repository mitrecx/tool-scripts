#!/bin/bash

# 实时同步文件/目录的Shell脚本: 使用 inotify-tools 监听本地文件变化并通过 rsync 同步到远程服务器

#################################### 功能说明 ####################################
# 实时文件/目录同步脚本, 用于监听本地(linux)目录的文件变化，并将变化实时同步到远程服务器(linux)。  
# 主要功能 
# - 实时监听：监听本地目录的文件创建、修改、删除、重命名等事件 
# - 远程同步：将本地文件变化实时同步到远程服务器
#
#################################### 使用方法 ####################################
# # 安装依赖
# sudo yum install inotify-tools rsync
# 或者离线安装: sudo rpm -ivh --force --nodeps *.rpm
#
# 基本用法
# chmod +x sync_files.sh
# ./sync_files.sh /local/path user@remote.com /remote/path
#
# 完整参数
# ./sync_files.sh -k ~/.ssh/id_rsa -e "*.tmp" -e ".git" -v /local/path user@remote.com /remote/path
##################################################################################

set -euo pipefail

# 默认配置
LOCAL_PATH=""
REMOTE_HOST=""
REMOTE_PATH=""
SSH_KEY=""
EXCLUDE_PATTERNS=()
VERBOSE=false
LOG_FILE="file_sync.log"
BATCH_SIZE=10
BATCH_TIMEOUT=2

# 日志函数
log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] [$level] $message" | tee -a "$LOG_FILE"
}

log_info() {
    log "INFO" "$@"
}

log_error() {
    log "ERROR" "$@"
}

log_debug() {
    if [[ "$VERBOSE" == "true" ]]; then
        log "DEBUG" "$@"
    fi
}

# 显示帮助信息
show_help() {
    cat << EOF
实时文件/目录同步工具 (Shell版本)

用法: $0 [选项] <本地路径> <远程主机> <远程路径>

参数:
    <本地路径>      要监听的本地目录路径
    <远程主机>      远程主机 (格式: user@host)
    <远程路径>      远程目录路径

选项:
    -k, --ssh-key <path>    SSH私钥路径
    -e, --exclude <pattern> 排除模式 (可多次指定)
    -v, --verbose           详细输出
    -h, --help              显示此帮助信息

示例:
    $0 /home/user/docs user@server.com /backup/docs
    $0 -k ~/.ssh/id_rsa -e "*.tmp" -e ".git" /project user@server:/backup/project

依赖:
    - inotify-tools (inotifywait命令)
    - rsync
    - ssh

EOF
}

# 检查依赖
check_dependencies() {
    local missing_deps=()
    
    if ! command -v inotifywait >/dev/null 2>&1; then
        missing_deps+=("inotify-tools")
    fi
    
    if ! command -v rsync >/dev/null 2>&1; then
        missing_deps+=("rsync")
    fi
    
    if ! command -v ssh >/dev/null 2>&1; then
        missing_deps+=("ssh")
    fi
    
    if [[ ${#missing_deps[@]} -gt 0 ]]; then
        log_error "缺少依赖: ${missing_deps[*]}"
        log_error "请安装缺少的软件包:"
        for dep in "${missing_deps[@]}"; do
            case "$dep" in
                "inotify-tools")
                    log_error "  Ubuntu/Debian: apt-get install inotify-tools"
                    log_error "  CentOS/RHEL: yum install inotify-tools"
                    ;;
                "rsync")
                    log_error "  Ubuntu/Debian: apt-get install rsync"
                    log_error "  CentOS/RHEL: yum install rsync"
                    ;;
                "ssh")
                    log_error "  Ubuntu/Debian: apt-get install openssh-client"
                    log_error "  CentOS/RHEL: yum install openssh-clients"
                    ;;
            esac
        done
        exit 1
    fi
}

# 解析命令行参数
parse_args() {
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
            -v|--verbose)
                VERBOSE=true
                shift
                ;;
            -h|--help)
                show_help
                exit 0
                ;;
            -*)
                log_error "未知选项: $1"
                show_help
                exit 1
                ;;
            *)
                if [[ -z "$LOCAL_PATH" ]]; then
                    LOCAL_PATH="$1"
                elif [[ -z "$REMOTE_HOST" ]]; then
                    REMOTE_HOST="$1"
                elif [[ -z "$REMOTE_PATH" ]]; then
                    REMOTE_PATH="$1"
                else
                    log_error "多余的参数: $1"
                    show_help
                    exit 1
                fi
                shift
                ;;
        esac
    done
    
    # 验证必需参数
    if [[ -z "$LOCAL_PATH" || -z "$REMOTE_HOST" || -z "$REMOTE_PATH" ]]; then
        log_error "缺少必需参数"
        show_help
        exit 1
    fi
    
    # 验证本地路径
    if [[ ! -d "$LOCAL_PATH" ]]; then
        log_error "本地路径不存在或不是目录: $LOCAL_PATH"
        exit 1
    fi
    
    # 转换为绝对路径
    LOCAL_PATH=$(realpath "$LOCAL_PATH")
}

# 构建rsync命令
build_rsync_cmd() {
    local cmd="rsync -avz --delete"
    
    # 添加排除模式
    for pattern in "${EXCLUDE_PATTERNS[@]}"; do
        cmd+=" --exclude='$pattern'"
    done
    
    # SSH配置
    if [[ -n "$SSH_KEY" ]]; then
        cmd+=" -e 'ssh -i $SSH_KEY'"
    fi
    
    echo "$cmd"
}

# 执行同步
execute_sync() {
    local source_path="${1:-}"
    local rsync_base_cmd
    rsync_base_cmd=$(build_rsync_cmd)
    
    local source_arg
    if [[ -n "$source_path" && -e "$source_path" ]]; then
        # 计算相对路径
        local rel_path
        rel_path=$(realpath --relative-to="$LOCAL_PATH" "$source_path" 2>/dev/null || echo "$source_path")
        
        if [[ "$rel_path" == "." ]]; then
            source_arg="$LOCAL_PATH/"
        else
            source_arg="$source_path"
        fi
    else
        source_arg="$LOCAL_PATH/"
    fi
    
    local target_arg="$REMOTE_HOST:$REMOTE_PATH/"
    local full_cmd="$rsync_base_cmd '$source_arg' '$target_arg'"
    
    log_debug "执行命令: $full_cmd"
    
    if eval "$full_cmd" 2>>"$LOG_FILE"; then
        if [[ -n "$source_path" ]]; then
            log_info "同步成功: $(basename "$source_path")"
        else
            log_info "全量同步成功"
        fi
        return 0
    else
        log_error "同步失败"
        return 1
    fi
}

# 测试远程连接
test_connection() {
    log_info "测试远程连接..."
    
    local ssh_cmd="ssh -o ConnectTimeout=10 -o BatchMode=yes"
    if [[ -n "$SSH_KEY" ]]; then
        ssh_cmd+=" -i '$SSH_KEY'"
    fi
    ssh_cmd+=" '$REMOTE_HOST' 'echo 连接测试成功'"
    
    if eval "$ssh_cmd" >/dev/null 2>&1; then
        log_info "远程连接测试成功"
        return 0
    else
        log_error "远程连接失败"
        return 1
    fi
}

# 初始同步
initial_sync() {
    log_info "开始初始全量同步..."
    execute_sync
}

# 处理信号
cleanup() {
    log_info "收到停止信号，正在清理..."
    
    # 终止后台进程
    if [[ -n "${INOTIFY_PID:-}" ]]; then
        kill "$INOTIFY_PID" 2>/dev/null || true
    fi
    
    if [[ -n "${SYNC_PID:-}" ]]; then
        kill "$SYNC_PID" 2>/dev/null || true
    fi
    
    # 清理临时文件
    rm -f /tmp/file_sync_events.$$
    
    log_info "清理完成，退出"
    exit 0
}

# 批处理同步
batch_sync() {
    local event_file="/tmp/file_sync_events.$$"
    local events=()
    local last_event_time=0
    
    while true; do
        if [[ -f "$event_file" ]]; then
            local current_time
            current_time=$(date +%s)
            
            # 读取事件
            mapfile -t new_events < "$event_file"
            
            if [[ ${#new_events[@]} -gt 0 ]]; then
                events+=("${new_events[@]}")
                last_event_time=$current_time
                
                # 清空事件文件
                > "$event_file"
            fi
            
            # 检查是否需要执行同步
            local should_sync=false
            
            if [[ ${#events[@]} -ge $BATCH_SIZE ]]; then
                should_sync=true
                log_debug "达到批处理大小限制: ${#events[@]}"
            elif [[ ${#events[@]} -gt 0 && $((current_time - last_event_time)) -ge $BATCH_TIMEOUT ]]; then
                should_sync=true
                log_debug "达到批处理时间限制"
            fi
            
            if [[ "$should_sync" == "true" ]]; then
                log_info "批量同步 ${#events[@]} 个事件"
                
                # 去重事件
                local unique_events
                IFS=$'\n' read -d '' -r -a unique_events < <(printf '%s\n' "${events[@]}" | sort -u) || true
                
                # 检查是否有目录级别的更改
                local has_dir_change=false
                for event in "${unique_events[@]}"; do
                    if [[ "$event" == *"$LOCAL_PATH"* ]] && [[ $(echo "$event" | grep -c "/") -le 1 ]]; then
                        has_dir_change=true
                        break
                    fi
                done
                
                if [[ "$has_dir_change" == "true" || ${#unique_events[@]} -gt 5 ]]; then
                    # 全量同步
                    execute_sync
                else
                    # 逐个同步
                    for event_path in "${unique_events[@]}"; do
                        execute_sync "$event_path"
                    done
                fi
                
                events=()
            fi
        fi
        
        sleep 0.1
    done
}

# 文件监听
start_monitoring() {
    local event_file="/tmp/file_sync_events.$$"
    
    # 启动批处理同步
    batch_sync &
    SYNC_PID=$!
    
    # inotify事件监听
    log_info "开始监听目录: $LOCAL_PATH"
    log_info "远程目标: $REMOTE_HOST:$REMOTE_PATH"
    
    inotifywait -m -r -e modify,create,delete,move \
        --format '%w%f %e' "$LOCAL_PATH" | \
    while read -r filepath event; do
        log_debug "检测到事件: $event -> $filepath"
        echo "$filepath" >> "$event_file"
    done &
    
    INOTIFY_PID=$!
    
    # 等待进程
    wait $INOTIFY_PID
}

# 主函数
main() {
    # 设置信号处理
    trap cleanup INT TERM EXIT
    
    # 检查依赖
    check_dependencies
    
    # 解析参数
    parse_args "$@"
    
    # 初始化日志
    log_info "启动文件同步器"
    log_info "本地路径: $LOCAL_PATH"
    log_info "远程主机: $REMOTE_HOST"
    log_info "远程路径: $REMOTE_PATH"
    
    if [[ ${#EXCLUDE_PATTERNS[@]} -gt 0 ]]; then
        log_info "排除模式: ${EXCLUDE_PATTERNS[*]}"
    fi
    
    # 测试连接
    if ! test_connection; then
        exit 1
    fi
    
    # 初始同步
    if ! initial_sync; then
        log_error "初始同步失败"
        exit 1
    fi
    
    # 开始监听
    start_monitoring
}

# 执行主函数
main "$@"