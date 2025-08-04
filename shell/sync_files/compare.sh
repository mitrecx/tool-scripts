#!/bin/bash

# 文件对比脚本 (使用 rsync)
# 用法: compare.sh dir_a user_name@remote_ip remote_dir_a
# 功能: 对比本地目录和远程目录的文件差异

# 检查参数数量
if [ $# -ne 3 ]; then
    echo "用法: $0 <本地目录> <用户名@远程IP> <远程目录>"
    echo "示例: $0 /path/to/local/dir user@192.168.1.100 /path/to/remote/dir"
    exit 1
fi

# 获取参数
LOCAL_DIR="$1"
REMOTE_HOST="$2"
REMOTE_DIR="$3"

# 检查本地目录是否存在
if [ ! -d "$LOCAL_DIR" ]; then
    echo "错误: 本地目录 '$LOCAL_DIR' 不存在"
    exit 1
fi

# 确保本地目录路径以斜杠结尾
if [[ "$LOCAL_DIR" != */ ]]; then
    LOCAL_DIR="$LOCAL_DIR/"
fi

# 确保远程目录路径以斜杠结尾
if [[ "$REMOTE_DIR" != */ ]]; then
    REMOTE_DIR="$REMOTE_DIR/"
fi

echo "正在对比本地目录: $LOCAL_DIR"
echo "远程目录: $REMOTE_HOST:$REMOTE_DIR"
echo "----------------------------------------"

# 执行rsync对比
RSYNC_OUTPUT=$(rsync -nrci --delete "$LOCAL_DIR" "$REMOTE_HOST:$REMOTE_DIR" 2>&1)

# 检查rsync是否成功执行
if [ $? -ne 0 ]; then
    echo "错误: 无法连接到远程主机 $REMOTE_HOST 或远程目录 '$REMOTE_DIR' 不存在"
    echo "rsync 错误信息:"
    echo "$RSYNC_OUTPUT"
    exit 1
fi

echo "需要同步的文件或目录列表:"
echo "------------------------------------"

# 使用你提供的对比逻辑
total_changes=0
while IFS= read -r line; do
    [ -z "$line" ] && continue

    FLAG=${line:0:11}
    PATH=${line:12}

    case "$FLAG" in
        "<f+++++++++")
            echo "[新增文件] $PATH"
            total_changes=$((total_changes + 1))
            ;;
        "<f"*)
            echo "[更新文件] $PATH"
            total_changes=$((total_changes + 1))
            ;;
        "cd+++++++++")
            echo "[新增目录] $PATH"
            total_changes=$((total_changes + 1))
            ;;
        "<d+++++++++")
            echo "[新增目录项] $PATH"
            total_changes=$((total_changes + 1))
            ;;
        *deleting*)
            echo "[将被删除] $PATH"
            total_changes=$((total_changes + 1))
            ;;
        *)
            # 只有当FLAG不为空且不是统计信息时才计数
            if [[ -n "$FLAG" && "$line" != *"sent"* && "$line" != *"total"* && "$line" != *"speedup"* ]]; then
                echo "[其他变更] $PATH (标志: $FLAG)"
                total_changes=$((total_changes + 1))
            fi
            ;;
    esac
done <<< "$RSYNC_OUTPUT"

echo "------------------------------------"
echo "统计结果: 发现 $total_changes 项变更"

if [ "$total_changes" -eq 0 ]; then
    echo "✓ 本地目录和远程目录完全同步，没有发现差异"
fi