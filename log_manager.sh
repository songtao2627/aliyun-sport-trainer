#!/bin/bash

# 日志管理脚本
# 用于查看、同步和管理训练日志

set -e

WORKSPACE="/workspace"
LOG_DIR="${WORKSPACE}/logs"

# 显示帮助信息
show_help() {
    echo "日志管理脚本使用说明:"
    echo ""
    echo "用法: $0 [命令] [选项]"
    echo ""
    echo "命令:"
    echo "  view [lines]     - 查看训练日志 (默认显示最后50行)"
    echo "  view-history [date] [lines] - 查看历史日志 (格式: YYYY-MM-DD)"
    echo "  list-history     - 列出本地所有历史日志"
    echo "  tail             - 实时跟踪训练日志"
    echo "  sync             - 立即同步日志到OSS"
    echo "  download [date]  - 从OSS下载指定日期的日志 (格式: YYYY-MM-DD)"
    echo "  list             - 列出OSS中的所有日志"
    echo "  clean            - 清理本地历史日志 (保留最近3天)"
    echo "  status           - 显示日志状态信息"
    echo ""
    echo "示例:"
    echo "  $0 view 100      - 查看最后100行日志"
    echo "  $0 view-history 2025-01-27 50  - 查看2025年1月27日的历史日志"
    echo "  $0 list-history  - 列出所有可用的历史日志"
    echo "  $0 download 2024-01-15  - 下载2024年1月15日的日志"
}

# 检查ossutil配置
check_ossutil() {
    if ! command -v ossutil &> /dev/null; then
        echo "错误: ossutil未安装"
        exit 1
    fi
    
    if [ ! -f "/workspace/.ossutilconfig" ]; then
        echo "错误: ossutil配置文件不存在，请先运行环境准备脚本"
        exit 1
    fi
}

# 获取实例ID
get_instance_id() {
    curl -s http://100.100.100.200/latest/meta-data/instance-id 2>/dev/null || echo 'unknown'
}

# 查看训练日志
view_logs() {
    local lines=${1:-50}
    
    if [ -f "${LOG_DIR}/training.log" ]; then
        echo "=== 训练日志 (最后 ${lines} 行) ==="
        tail -n "$lines" "${LOG_DIR}/training.log"
    else
        echo "训练日志文件不存在: ${LOG_DIR}/training.log"
    fi
    
    echo ""
    
    if [ -f "${LOG_DIR}/prepare.log" ]; then
        echo "=== 环境准备日志 (最后 ${lines} 行) ==="
        tail -n "$lines" "${LOG_DIR}/prepare.log"
    fi
}

# 实时跟踪日志
tail_logs() {
    echo "实时跟踪训练日志 (按 Ctrl+C 退出)..."
    if [ -f "${LOG_DIR}/training.log" ]; then
        tail -f "${LOG_DIR}/training.log"
    else
        echo "训练日志文件不存在，等待创建..."
        while [ ! -f "${LOG_DIR}/training.log" ]; do
            sleep 1
        done
        tail -f "${LOG_DIR}/training.log"
    fi
}

# 同步日志到OSS
sync_logs() {
    check_ossutil
    
    local instance_id=$(get_instance_id)
    local log_prefix="logs/${instance_id}/$(date '+%Y-%m-%d')"
    
    echo "正在同步日志到OSS..."
    echo "目标路径: oss://${OSS_BUCKET}/${log_prefix}/"
    
    if ossutil cp ${LOG_DIR}/ oss://${OSS_BUCKET}/${log_prefix}/ --recursive --config-file /workspace/.ossutilconfig --update; then
        echo "日志同步成功"
        echo "同步时间: $(date)" > "${WORKSPACE}/.last_log_sync_manual"
    else
        echo "日志同步失败"
        exit 1
    fi
}

# 从OSS下载日志
download_logs() {
    check_ossutil
    
    local date_str=${1:-$(date '+%Y-%m-%d')}
    local instance_id=$(get_instance_id)
    local log_path="oss://${OSS_BUCKET}/logs/${instance_id}/${date_str}/"
    local local_path="${LOG_DIR}/downloaded/${date_str}"
    
    echo "正在从OSS下载 ${date_str} 的日志..."
    echo "源路径: ${log_path}"
    echo "本地路径: ${local_path}"
    
    if ossutil ls "$log_path" --config-file /workspace/.ossutilconfig > /dev/null 2>&1; then
        mkdir -p "$local_path"
        if ossutil cp "$log_path" "$local_path/" --recursive --config-file /workspace/.ossutilconfig; then
            echo "日志下载成功"
            echo "下载的文件:"
            ls -la "$local_path"
        else
            echo "日志下载失败"
            exit 1
        fi
    else
        echo "OSS中未找到 ${date_str} 的日志"
        exit 1
    fi
}

# 列出OSS中的日志
list_logs() {
    check_ossutil
    
    local instance_id=$(get_instance_id)
    local log_prefix="logs/${instance_id}/"
    
    echo "OSS中的日志列表 (实例ID: ${instance_id}):"
    echo "路径: oss://${OSS_BUCKET}/${log_prefix}"
    echo ""
    
    if ossutil ls oss://${OSS_BUCKET}/${log_prefix} --config-file /workspace/.ossutilconfig -d; then
        echo ""
        echo "使用 '$0 download YYYY-MM-DD' 下载特定日期的日志"
    else
        echo "未找到日志或访问失败"
    fi
}

# 清理本地日志
clean_logs() {
    echo "清理本地日志..."
    
    # 注意: 在抢占式实例环境下，本地日志在实例重启后会自动消失
    # history目录只会恢复最近3天的日志，downloaded目录是临时下载的日志
    # 因此清理3天前的历史日志在抢占式实例中是冗余的操作
    
    # 清理大于100MB的当前日志文件，防止占满磁盘空间
    local truncated_count=0
    while IFS= read -r -d '' file; do
        truncate -s 50M "$file" 2>/dev/null && ((truncated_count++))
    done < <(find "$LOG_DIR" -name "*.log" -size +100M -mtime +1 -print0 2>/dev/null)
    
    if [ $truncated_count -gt 0 ]; then
        echo "已截断 ${truncated_count} 个过大的日志文件 (>100MB -> 50MB)"
    else
        echo "未发现需要截断的大日志文件"
    fi
    
    # 显示当前日志目录使用情况
    echo "当前日志目录使用情况:"
    du -sh "$LOG_DIR" 2>/dev/null || echo "无法获取目录大小"
    
    echo "日志清理完成"
}

# 查看历史日志
view_history_logs() {
    local date_str=${1}
    local lines=${2:-50}
    
    if [ -z "$date_str" ]; then
        echo "错误: 请指定日期 (格式: YYYY-MM-DD)"
        echo "使用 '$0 list-history' 查看可用的历史日志"
        exit 1
    fi
    
    local history_dir="${LOG_DIR}/history/${date_str}"
    local downloaded_dir="${LOG_DIR}/downloaded/${date_str}"
    
    # 检查历史日志目录
    if [ -d "$history_dir" ]; then
        echo "=== ${date_str} 历史日志 (恢复的日志) ==="
        if [ -f "${history_dir}/training.log" ]; then
            echo "--- 训练日志 (最后 ${lines} 行) ---"
            tail -n "$lines" "${history_dir}/training.log"
            echo ""
        fi
        
        if [ -f "${history_dir}/prepare.log" ]; then
            echo "--- 环境准备日志 (最后 ${lines} 行) ---"
            tail -n "$lines" "${history_dir}/prepare.log"
            echo ""
        fi
        
        if [ -f "${history_dir}/service.log" ]; then
            echo "--- 服务日志 (最后 ${lines} 行) ---"
            tail -n "$lines" "${history_dir}/service.log"
            echo ""
        fi
        
        # 显示目录中的所有日志文件
        echo "--- 该日期的所有日志文件 ---"
        ls -la "$history_dir"/*.log 2>/dev/null || echo "未找到日志文件"
        
    elif [ -d "$downloaded_dir" ]; then
        echo "=== ${date_str} 下载的日志 ==="
        if [ -f "${downloaded_dir}/training.log" ]; then
            echo "--- 训练日志 (最后 ${lines} 行) ---"
            tail -n "$lines" "${downloaded_dir}/training.log"
            echo ""
        fi
        
        if [ -f "${downloaded_dir}/prepare.log" ]; then
            echo "--- 环境准备日志 (最后 ${lines} 行) ---"
            tail -n "$lines" "${downloaded_dir}/prepare.log"
            echo ""
        fi
        
        if [ -f "${downloaded_dir}/service.log" ]; then
            echo "--- 服务日志 (最后 ${lines} 行) ---"
            tail -n "$lines" "${downloaded_dir}/service.log"
            echo ""
        fi
        
        # 显示目录中的所有日志文件
        echo "--- 该日期的所有日志文件 ---"
        ls -la "$downloaded_dir"/*.log 2>/dev/null || echo "未找到日志文件"
        
    else
        echo "未找到 ${date_str} 的历史日志"
        echo "可用的历史日志:"
        list_history_logs
        exit 1
    fi
}

# 列出本地历史日志
list_history_logs() {
    echo "=== 本地历史日志列表 ==="
    
    local history_dir="${LOG_DIR}/history"
    local downloaded_dir="${LOG_DIR}/downloaded"
    local found=false
    
    if [ -d "$history_dir" ]; then
        echo "恢复的历史日志:"
        for date_dir in "$history_dir"/20*; do
            if [ -d "$date_dir" ]; then
                local date_name=$(basename "$date_dir")
                local file_count=$(find "$date_dir" -name "*.log" | wc -l)
                local total_size=$(du -sh "$date_dir" 2>/dev/null | cut -f1)
                echo "  ${date_name} (${file_count} 个文件, ${total_size})"
                found=true
            fi
        done
        
        if [ "$found" = false ]; then
            echo "  (无恢复的历史日志)"
        fi
    fi
    
    echo ""
    found=false
    
    if [ -d "$downloaded_dir" ]; then
        echo "下载的历史日志:"
        for date_dir in "$downloaded_dir"/20*; do
            if [ -d "$date_dir" ]; then
                local date_name=$(basename "$date_dir")
                local file_count=$(find "$date_dir" -name "*.log" | wc -l)
                local total_size=$(du -sh "$date_dir" 2>/dev/null | cut -f1)
                echo "  ${date_name} (${file_count} 个文件, ${total_size})"
                found=true
            fi
        done
        
        if [ "$found" = false ]; then
            echo "  (无下载的历史日志)"
        fi
    fi
    
    echo ""
    echo "使用 '$0 view-history YYYY-MM-DD' 查看特定日期的日志"
}

# 显示日志状态
show_status() {
    echo "=== 日志状态信息 ==="
    echo "实例ID: $(get_instance_id)"
    echo "日志目录: ${LOG_DIR}"
    echo ""
    
    echo "本地日志文件:"
    if [ -d "$LOG_DIR" ]; then
        find "$LOG_DIR" -name "*.log" -exec ls -lh {} \; 2>/dev/null || echo "未找到日志文件"
    else
        echo "日志目录不存在"
    fi
    
    echo ""
    echo "最后同步时间:"
    if [ -f "${WORKSPACE}/.last_log_sync" ]; then
        local last_sync=$(cat "${WORKSPACE}/.last_log_sync")
        echo "自动同步: $(date -d @${last_sync} 2>/dev/null || echo '未知')"
    else
        echo "自动同步: 从未同步"
    fi
    
    if [ -f "${WORKSPACE}/.last_log_sync_manual" ]; then
        echo "手动同步: $(cat "${WORKSPACE}/.last_log_sync_manual")"
    else
        echo "手动同步: 从未同步"
    fi
    
    echo ""
    echo "历史日志统计:"
    local history_count=0
    local downloaded_count=0
    
    if [ -d "${LOG_DIR}/history" ]; then
        history_count=$(find "${LOG_DIR}/history" -name "20*" -type d | wc -l)
    fi
    
    if [ -d "${LOG_DIR}/downloaded" ]; then
        downloaded_count=$(find "${LOG_DIR}/downloaded" -name "20*" -type d | wc -l)
    fi
    
    echo "恢复的历史日志: ${history_count} 天"
    echo "下载的历史日志: ${downloaded_count} 天"
    
    echo ""
    echo "磁盘使用情况:"
    df -h "$LOG_DIR" 2>/dev/null || echo "无法获取磁盘信息"
}

# 主程序
case "${1:-help}" in
    "view")
        view_logs "$2"
        ;;
    "view-history")
        view_history_logs "$2" "$3"
        ;;
    "list-history")
        list_history_logs
        ;;
    "tail")
        tail_logs
        ;;
    "sync")
        sync_logs
        ;;
    "download")
        download_logs "$2"
        ;;
    "list")
        list_logs
        ;;
    "clean")
        clean_logs
        ;;
    "status")
        show_status
        ;;
    "help"|*)
        show_help
        ;;
esac