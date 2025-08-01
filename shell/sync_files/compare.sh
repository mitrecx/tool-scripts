#!/bin/bash

# 目录对比脚本
# 用于对比本地和远程目录的差异

set -euo pipefail

# 默认配置
LOCAL_PATH=""
REMOTE_HOST=""
REMOTE_PATH=""
SSH_KEY=""
EXCLUDE_PATTERNS=()
VERBOSE=false
DETAILED=false
CHECKSUM=false
OUTPUT_FORMAT="text"
OUTPUT_FILE=""
TEMP_DIR="/tmp/dir_compare_$$"

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# 统计信息
STATS_MISSING_LOCAL=0
STATS_MISSING_REMOTE=0
STATS_DIFFERENT=0
STATS_IDENTICAL=0
STATS_TOTAL=0

# 日志函数
log_info() {
    echo -e "${BLUE}[INFO]${NC} $*"
}

log_success() {
    echo -e "${GREEN}[OK]${NC} $*"
}

log_warning() {
    echo -e "${YELLOW}[WARN]${NC} $*"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $*"
}

log_diff() {
    echo -e "${CYAN}[DIFF]${NC} $*"
}

log_debug() {
    if [[ "$VERBOSE" == "true" ]]; then
        echo -e "${BOLD}[DEBUG]${NC} $*"
    fi
}

# 显示帮助信息
show_help() {
    cat << EOF
目录对比工具

用法: $0 [选项] <本地路径> <远程主机> <远程路径>

参数:
    <本地路径>      本地目录路径
    <远程主机>      远程主机 (格式: user@host)
    <远程路径>      远程目录路径

选项:
    -k, --ssh-key <path>    SSH私钥路径
    -e, --exclude <pattern> 排除模式 (可多次指定)
    -c, --checksum          使用校验和对比文件内容 (较慢但更准确)
    -d, --detailed          显示详细差异信息
    -v, --verbose           详细输出
    -f, --format <format>   输出格式: text|json|csv (默认: text)
    -o, --output <file>     输出到文件
    --summary-only          仅显示摘要统计
    -h, --help              显示此帮助信息

输出说明:
    [MISSING_LOCAL]   远程有但本地没有的文件
    [MISSING_REMOTE]  本地有但远程没有的文件
    [DIFFERENT]       两边都有但内容不同的文件
    [IDENTICAL]       两边都有且内容相同的文件

示例:
    # 基本对比
    $0 /home/user/docs user@server.com /backup/docs

    # 使用校验和和详细输出
    $0 -c -d -k ~/.ssh/id_rsa /project user@server:/backup/project

    # 排除特定文件并输出到JSON
    $0 -e "*.tmp" -e ".git" -f json -o compare_result.json /local user@remote /remote

EOF
}

# 清理函数
cleanup() {
    if [[ -d "$TEMP_DIR" ]]; then
        rm -rf "$TEMP_DIR"
        log_debug "清理临时目录: $TEMP_DIR"
    fi
}

# 检查依赖
check_dependencies() {
    local missing_deps=()
    
    for cmd in rsync ssh find sort awk; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing_deps+=("$cmd")
        fi
    done
    
    if [[ ${#missing_deps[@]} -gt 0 ]]; then
        log_error "缺少依赖: ${missing_deps[*]}"
        exit 1
    fi
}

# 解析命令行参数
parse_args() {
    local summary_only=false
    
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
            -c|--checksum)
                CHECKSUM=true
                shift
                ;;
            -d|--detailed)
                DETAILED=true
                shift
                ;;
            -v|--verbose)
                VERBOSE=true
                shift
                ;;
            -f|--format)
                OUTPUT_FORMAT="$2"
                case "$OUTPUT_FORMAT" in
                    text|json|csv) ;;
                    *) log_error "不支持的输出格式: $OUTPUT_FORMAT"; exit 1 ;;
                esac
                shift 2
                ;;
            -o|--output)
                OUTPUT_FILE="$2"
                shift 2
                ;;
            --summary-only)
                summary_only=true
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
    
    # 如果只显示摘要，关闭详细输出
    if [[ "$summary_only" == "true" ]]; then
        DETAILED=false
    fi
}

# 构建rsync命令参数
build_rsync_args() {
    local args="-an"  # archive + dry-run
    
    if [[ "$CHECKSUM" == "true" ]]; then
        args+="c"  # 使用校验和
    fi
    
    # 添加排除模式
    for pattern in "${EXCLUDE_PATTERNS[@]}"; do
        args+=" --exclude='$pattern'"
    done
    
    # SSH配置
    if [[ -n "$SSH_KEY" ]]; then
        args+=" -e 'ssh -i $SSH_KEY'"
    fi
    
    echo "$args"
}

# 获取文件列表
get_file_list() {
    local path="$1"
    local is_remote="$2"
    local output_file="$3"
    
    local find_cmd="find '$path' -type f"
    
    # 添加排除模式
    for pattern in "${EXCLUDE_PATTERNS[@]}"; do
        find_cmd+=" ! -name '$pattern'"
    done
    
    if [[ "$is_remote" == "true" ]]; then
        local ssh_cmd="ssh"
        if [[ -n "$SSH_KEY" ]]; then
            ssh_cmd+=" -i '$SSH_KEY'"
        fi
        ssh_cmd+=" '$REMOTE_HOST' \"$find_cmd\""
        
        log_debug "远程命令: $ssh_cmd"
        eval "$ssh_cmd" | sed "s|^$path/||" | sort > "$output_file"
    else
        log_debug "本地命令: $find_cmd"
        eval "$find_cmd" | sed "s|^$path/||" | sort > "$output_file"
    fi
}

# 获取文件信息（大小、修改时间、权限等）
get_file_info() {
    local file_path="$1"
    local is_remote="$2"
    
    local stat_cmd="stat -c '%s %Y %a' '$file_path' 2>/dev/null || echo 'ERROR'"
    
    if [[ "$is_remote" == "true" ]]; then
        local ssh_cmd="ssh"
        if [[ -n "$SSH_KEY" ]]; then
            ssh_cmd+=" -i '$SSH_KEY'"
        fi
        ssh_cmd+=" '$REMOTE_HOST' \"$stat_cmd\""
        eval "$ssh_cmd" 2>/dev/null || echo "ERROR"
    else
        eval "$stat_cmd" 2>/dev/null || echo "ERROR"
    fi
}

# 获取文件校验和
get_file_checksum() {
    local file_path="$1"
    local is_remote="$2"
    
    local checksum_cmd="md5sum '$file_path' 2>/dev/null | cut -d' ' -f1 || echo 'ERROR'"
    
    if [[ "$is_remote" == "true" ]]; then
        local ssh_cmd="ssh"
        if [[ -n "$SSH_KEY" ]]; then
            ssh_cmd+=" -i '$SSH_KEY'"
        fi
        ssh_cmd+=" '$REMOTE_HOST' \"$checksum_cmd\""
        eval "$ssh_cmd" 2>/dev/null || echo "ERROR"
    else
        eval "$checksum_cmd" 2>/dev/null || echo "ERROR"
    fi
}

# 对比两个文件
compare_files() {
    local rel_path="$1"
    local local_full_path="$LOCAL_PATH/$rel_path"
    local remote_full_path="$REMOTE_PATH/$rel_path"
    
    log_debug "对比文件: $rel_path"
    
    # 获取文件信息
    local local_info
    local remote_info
    local_info=$(get_file_info "$local_full_path" false)
    remote_info=$(get_file_info "$remote_full_path" true)
    
    if [[ "$local_info" == "ERROR" || "$remote_info" == "ERROR" ]]; then
        return 1
    fi
    
    # 解析文件信息
    local local_size local_mtime local_perm
    local remote_size remote_mtime remote_perm
    read -r local_size local_mtime local_perm <<< "$local_info"
    read -r remote_size remote_mtime remote_perm <<< "$remote_info"
    
    # 首先检查大小和修改时间
    if [[ "$local_size" != "$remote_size" || "$local_mtime" != "$remote_mtime" ]]; then
        echo "DIFFERENT_META"
        return 0
    fi
    
    # 如果启用校验和检查
    if [[ "$CHECKSUM" == "true" ]]; then
        local local_checksum remote_checksum
        local_checksum=$(get_file_checksum "$local_full_path" false)
        remote_checksum=$(get_file_checksum "$remote_full_path" true)
        
        if [[ "$local_checksum" == "ERROR" || "$remote_checksum" == "ERROR" ]]; then
            echo "ERROR"
            return 1
        fi
        
        if [[ "$local_checksum" != "$remote_checksum" ]]; then
            echo "DIFFERENT_CONTENT"
            return 0
        fi
    fi
    
    echo "IDENTICAL"
    return 0
}

# 执行对比
perform_comparison() {
    log_info "开始目录对比..."
    log_info "本地路径: $LOCAL_PATH"
    log_info "远程路径: $REMOTE_HOST:$REMOTE_PATH"
    
    # 创建临时目录
    mkdir -p "$TEMP_DIR"
    
    local local_files="$TEMP_DIR/local_files.txt"
    local remote_files="$TEMP_DIR/remote_files.txt"
    local all_files="$TEMP_DIR/all_files.txt"
    local results="$TEMP_DIR/results.txt"
    
    # 获取文件列表
    log_info "获取本地文件列表..."
    get_file_list "$LOCAL_PATH" false "$local_files"
    local local_count
    local_count=$(wc -l < "$local_files")
    log_info "本地文件数量: $local_count"
    
    log_info "获取远程文件列表..."
    get_file_list "$REMOTE_PATH" true "$remote_files"
    local remote_count
    remote_count=$(wc -l < "$remote_files")
    log_info "远程文件数量: $remote_count"
    
    # 合并并去重文件列表
    sort -u "$local_files" "$remote_files" > "$all_files"
    local total_unique
    total_unique=$(wc -l < "$all_files")
    log_info "唯一文件总数: $total_unique"
    
    # 开始对比
    log_info "开始逐文件对比..."
    
    local current=0
    while IFS= read -r file; do
        ((current++))
        STATS_TOTAL=$current
        
        if [[ $((current % 100)) -eq 0 ]] || [[ "$VERBOSE" == "true" ]]; then
            log_info "进度: $current/$total_unique"
        fi
        
        local status=""
        local detail=""
        
        # 检查文件在哪边存在
        local exists_local=false
        local exists_remote=false
        
        if grep -Fxq "$file" "$local_files"; then
            exists_local=true
        fi
        
        if grep -Fxq "$file" "$remote_files"; then
            exists_remote=true
        fi
        
        if [[ "$exists_local" == "true" && "$exists_remote" == "true" ]]; then
            # 两边都存在，对比内容
            local compare_result
            compare_result=$(compare_files "$file")
            
            case "$compare_result" in
                "IDENTICAL")
                    status="IDENTICAL"
                    ((STATS_IDENTICAL++))
                    ;;
                "DIFFERENT_META"|"DIFFERENT_CONTENT")
                    status="DIFFERENT"
                    detail="$compare_result"
                    ((STATS_DIFFERENT++))
                    ;;
                "ERROR")
                    status="ERROR"
                    detail="比较失败"
                    ;;
            esac
        elif [[ "$exists_local" == "true" && "$exists_remote" == "false" ]]; then
            status="MISSING_REMOTE"
            ((STATS_MISSING_REMOTE++))
        elif [[ "$exists_local" == "false" && "$exists_remote" == "true" ]]; then
            status="MISSING_LOCAL"
            ((STATS_MISSING_LOCAL++))
        fi
        
        # 记录结果
        if [[ -n "$detail" ]]; then
            echo "$status|$file|$detail" >> "$results"
        else
            echo "$status|$file|" >> "$results"
        fi
        
    done < "$all_files"
    
    log_success "对比完成！"
    
    # 输出结果
    output_results "$results"
}

# 输出结果
output_results() {
    local results_file="$1"
    
    case "$OUTPUT_FORMAT" in
        "json")
            output_json "$results_file"
            ;;
        "csv")
            output_csv "$results_file"
            ;;
        *)
            output_text "$results_file"
            ;;
    esac
}

# 文本格式输出
output_text() {
    local results_file="$1"
    local output=""
    
    # 生成报告头部
    output+="========================================\n"
    output+="目录对比报告\n"
    output+="========================================\n"
    output+="对比时间: $(date '+%Y-%m-%d %H:%M:%S')\n"
    output+="本地路径: $LOCAL_PATH\n"
    output+="远程路径: $REMOTE_HOST:$REMOTE_PATH\n"
    output+="使用校验和: $([ "$CHECKSUM" == "true" ] && echo "是" || echo "否")\n"
    output+="排除模式: ${EXCLUDE_PATTERNS[*]:-无}\n"
    output+="\n"
    
    # 统计摘要
    output+="========================================\n"
    output+="统计摘要\n"
    output+="========================================\n"
    output+="总文件数: $STATS_TOTAL\n"
    output+="相同文件: $STATS_IDENTICAL\n"
    output+="不同文件: $STATS_DIFFERENT\n"
    output+="本地缺失: $STATS_MISSING_LOCAL\n"
    output+="远程缺失: $STATS_MISSING_REMOTE\n"
    output+="\n"
    
    # 如果启用详细模式，显示差异列表
    if [[ "$DETAILED" == "true" && -f "$results_file" ]]; then
        # 本地缺失的文件
        local missing_local
        missing_local=$(grep "^MISSING_LOCAL|" "$results_file" | cut -d'|' -f2 || true)
        if [[ -n "$missing_local" ]]; then
            output+="========================================\n"
            output+="本地缺失的文件 ($STATS_MISSING_LOCAL)\n"
            output+="========================================\n"
            while IFS= read -r file; do
                output+="$(printf "${RED}[-]${NC} %s\n" "$file")\n"
            done <<< "$missing_local"
            output+="\n"
        fi
        
        # 远程缺失的文件
        local missing_remote
        missing_remote=$(grep "^MISSING_REMOTE|" "$results_file" | cut -d'|' -f2 || true)
        if [[ -n "$missing_remote" ]]; then
            output+="========================================\n"
            output+="远程缺失的文件 ($STATS_MISSING_REMOTE)\n"
            output+="========================================\n"    
            while IFS= read -r file; do
                output+="$(printf "${YELLOW}[+]${NC} %s\n" "$file")\n"
            done <<< "$missing_remote"
            output+="\n"
        fi
        
        # 内容不同的文件
        local different_files
        different_files=$(grep "^DIFFERENT|" "$results_file" || true)
        if [[ -n "$different_files" ]]; then
            output+="========================================\n"
            output+="内容不同的文件 ($STATS_DIFFERENT)\n"
            output+="========================================\n"
            while IFS='|' read -r status file detail; do
                if [[ -n "$detail" ]]; then
                    output+="$(printf "${CYAN}[≠]${NC} %s (%s)\n" "$file" "$detail")\n"
                else
                    output+="$(printf "${CYAN}[≠]${NC} %s\n" "$file")\n"
                fi
            done <<< "$different_files"
            output+="\n"
        fi
    fi
    
    # 输出结果
    if [[ -n "$OUTPUT_FILE" ]]; then
        echo -e "$output" > "$OUTPUT_FILE"
        log_success "结果已保存到: $OUTPUT_FILE"
    else
        echo -e "$output"
    fi
}

# JSON格式输出
output_json() {
    local results_file="$1"
    local json_output=""
    
    json_output="{\n"
    json_output+="  \"comparison_info\": {\n"
    json_output+="    \"timestamp\": \"$(date -Iseconds)\",\n"
    json_output+="    \"local_path\": \"$LOCAL_PATH\",\n"
    json_output+="    \"remote_host\": \"$REMOTE_HOST\",\n"
    json_output+="    \"remote_path\": \"$REMOTE_PATH\",\n"
    json_output+="    \"use_checksum\": $([[ "$CHECKSUM" == "true" ]] && echo "true" || echo "false"),\n"
    json_output+="    \"exclude_patterns\": [$(printf '"%s",' "${EXCLUDE_PATTERNS[@]}" | sed 's/,$//')]\\n"
    json_output+="  },\n"
    
    json_output+="  \"statistics\": {\n"
    json_output+="    \"total_files\": $STATS_TOTAL,\n"
    json_output+="    \"identical_files\": $STATS_IDENTICAL,\n"
    json_output+="    \"different_files\": $STATS_DIFFERENT,\n"
    json_output+="    \"missing_local\": $STATS_MISSING_LOCAL,\n"
    json_output+="    \"missing_remote\": $STATS_MISSING_REMOTE\n"
    json_output+="  },\n"
    
    json_output+="  \"results\": [\n"
    
    local first=true
    while IFS='|' read -r status file detail; do
        if [[ "$first" == "true" ]]; then
            first=false
        else
            json_output+=",\n"
        fi
        
        json_output+="    {\n"
        json_output+="      \"status\": \"$status\",\n"
        json_output+="      \"file\": \"$file\"\n"
        if [[ -n "$detail" ]]; then
            json_output+=",\n      \"detail\": \"$detail\"\n"
        fi
        json_output+="    }"
    done < "$results_file"
    
    json_output+="\n  ]\n"
    json_output+="}\n"
    
    # 输出结果
    if [[ -n "$OUTPUT_FILE" ]]; then
        echo -e "$json_output" > "$OUTPUT_FILE"
        log_success "JSON结果已保存到: $OUTPUT_FILE"
    else
        echo -e "$json_output"
    fi
}

# CSV格式输出
output_csv() {
    local results_file="$1"
    local csv_output=""
    
    # CSV头部
    csv_output="Status,File,Detail,Timestamp\n"
    
    # CSV数据
    while IFS='|' read -r status file detail; do
        csv_output+="\"$status\",\"$file\",\"$detail\",\"$(date -Iseconds)\"\n"
    done < "$results_file"
    
    # 输出结果
    if [[ -n "$OUTPUT_FILE" ]]; then
        echo -e "$csv_output" > "$OUTPUT_FILE"
        log_success "CSV结果已保存到: $OUTPUT_FILE"
    else
        echo -e "$csv_output"
    fi
}

# 测试远程连接
test_remote_connection() {
    log_info "测试远程连接..."
    
    local ssh_cmd="ssh -o ConnectTimeout=10 -o BatchMode=yes"
    if [[ -n "$SSH_KEY" ]]; then
        ssh_cmd+=" -i '$SSH_KEY'"
    fi
    ssh_cmd+=" '$REMOTE_HOST' 'echo 连接测试成功'"
    
    if eval "$ssh_cmd" >/dev/null 2>&1; then
        log_success "远程连接测试成功"
        return 0
    else
        log_error "远程连接失败"
        log_error "请检查:"
        log_error "  1. 远程主机地址: $REMOTE_HOST"
        log_error "  2. SSH密钥配置: ${SSH_KEY:-默认}"
        log_error "  3. 网络连接状态"
        return 1
    fi
}

# 验证远程路径
verify_remote_path() {
    log_info "验证远程路径..."
    
    local ssh_cmd="ssh"
    if [[ -n "$SSH_KEY" ]]; then
        ssh_cmd+=" -i '$SSH_KEY'"
    fi
    ssh_cmd+=" '$REMOTE_HOST' 'test -d \"$REMOTE_PATH\"'"
    
    if eval "$ssh_cmd" 2>/dev/null; then
        log_success "远程路径验证成功: $REMOTE_PATH"
        return 0
    else
        log_error "远程路径不存在或不是目录: $REMOTE_PATH"
        return 1
    fi
}

# 显示进度条
show_progress() {
    local current="$1"
    local total="$2"
    local width=50
    local percent=$((current * 100 / total))
    local filled=$((current * width / total))
    local empty=$((width - filled))
    
    printf "\r["
    printf "%${filled}s" | tr ' ' '='
    printf "%${empty}s" | tr ' ' '-'
    printf "] %d%% (%d/%d)" "$percent" "$current" "$total"
}

# 主函数
main() {
    # 设置清理陷阱
    trap cleanup EXIT INT TERM
    
    log_info "目录对比工具启动"
    
    # 检查依赖
    check_dependencies
    
    # 解析参数
    parse_args "$@"
    
    log_debug "配置信息:"
    log_debug "  本地路径: $LOCAL_PATH"
    log_debug "  远程主机: $REMOTE_HOST"
    log_debug "  远程路径: $REMOTE_PATH"
    log_debug "  SSH密钥: ${SSH_KEY:-默认}"
    log_debug "  使用校验和: $CHECKSUM"
    log_debug "  详细输出: $DETAILED"
    log_debug "  输出格式: $OUTPUT_FORMAT"
    log_debug "  输出文件: ${OUTPUT_FILE:-标准输出}"
    log_debug "  排除模式: ${EXCLUDE_PATTERNS[*]:-无}"
    
    # 测试连接
    if ! test_remote_connection; then
        exit 1
    fi
    
    # 验证路径
    if ! verify_remote_path; then
        exit 1
    fi
    
    # 执行对比
    perform_comparison
    
    # 输出最终摘要
    echo
    log_success "对比完成！"
    if [[ $STATS_DIFFERENT -gt 0 || $STATS_MISSING_LOCAL -gt 0 || $STATS_MISSING_REMOTE -gt 0 ]]; then
        log_warning "发现差异: 不同文件($STATS_DIFFERENT) 本地缺失($STATS_MISSING_LOCAL) 远程缺失($STATS_MISSING_REMOTE)"
        exit 2
    else
        log_success "目录完全同步！所有 $STATS_IDENTICAL 个文件都相同"
        exit 0
    fi
}

# 执行主函数
main "$@"