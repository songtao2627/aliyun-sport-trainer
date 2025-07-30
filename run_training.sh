#!/bin/bash

# ML训练主脚本
# 该脚本负责执行训练过程，并处理checkpoint保存和实例回收

set -e

# 加载配置文件
if [ -f "/workspace/config.env" ]; then
    echo "加载配置文件: /workspace/config.env"
    source /workspace/config.env
fi

# 日志函数
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a /workspace/logs/training.log
}

# 同步日志到OSS的函数
sync_logs_to_oss() {
    local force_sync=${1:-false}
    
    # 检查是否需要同步（每5分钟或强制同步）
    local last_sync_file="/workspace/.last_log_sync"
    local current_time=$(date +%s)
    local should_sync=false
    
    if [ "$force_sync" = "true" ]; then
        should_sync=true
    elif [ ! -f "$last_sync_file" ]; then
        should_sync=true
    else
        local last_sync_time=$(cat "$last_sync_file" 2>/dev/null || echo "0")
        local time_diff=$((current_time - last_sync_time))
        if [ $time_diff -gt 300 ]; then  # 5分钟 = 300秒
            should_sync=true
        fi
    fi
    
    if [ "$should_sync" = "true" ]; then
        if command -v ossutil &> /dev/null; then
            # 创建带时间戳的日志目录
            local instance_id=$(curl -s http://100.100.100.200/latest/meta-data/instance-id 2>/dev/null || echo 'unknown')
            local log_prefix="logs/${instance_id}/$(date '+%Y-%m-%d')"
            
            # 同步所有日志文件到OSS
            if ossutil cp ${LOG_DIR}/ oss://${OSS_BUCKET}/${log_prefix}/ --recursive --config-file /workspace/.ossutilconfig --update; then
                echo "$current_time" > "$last_sync_file"
                if [ "$force_sync" = "true" ]; then
                    log "日志已强制同步到OSS: oss://${OSS_BUCKET}/${log_prefix}/"
                fi
            else
                log "警告: 日志同步到OSS失败"
            fi
        else
            log "警告: ossutil未安装，无法同步日志到OSS"
        fi
    fi
}

log "开始训练任务..."

# 首先执行环境准备
log "执行环境准备脚本..."
/workspace/prepare_environment.sh

# 定义变量
WORKSPACE="/workspace"
DATA_DIR="${WORKSPACE}/data"
MODEL_DIR="${WORKSPACE}/models"
CHECKPOINT_DIR="${WORKSPACE}/checkpoints"
LOG_DIR="${WORKSPACE}/logs"

# 创建必要的目录
mkdir -p ${CHECKPOINT_DIR}
mkdir -p ${LOG_DIR}

# 标志文件，用于指示是否应该正常退出
SHUTDOWN_FLAG="${WORKSPACE}/.shutdown"

# 检查阿里云抢占式实例回收信号的函数
check_spot_interruption() {
    # 通过阿里云元数据服务检查实例状态
    if command -v curl &> /dev/null; then
        # 获取元数据访问凭证
        TOKEN=$(curl -s -X PUT "http://100.100.100.200/latest/api/token" -H "X-aliyun-ecs-metadata-token-ttl-seconds:300" 2>/dev/null || echo "")
        
        if [ ! -z "$TOKEN" ]; then
            # 查询抢占式实例是否即将被回收
            TERMINATION_TIME=$(curl -s -H "X-aliyun-ecs-metadata-token: $TOKEN" http://100.100.100.200/latest/meta-data/instance/spot/termination-time 2>/dev/null || echo "")
            
            if [ ! -z "$TERMINATION_TIME" ] && [ "$TERMINATION_TIME" != "404 - Not Found" ]; then
                echo "检测到实例即将被回收，回收时间: $TERMINATION_TIME"
                return 0
            fi
        fi
    fi
    
    return 1
}

# 保存checkpoint到OSS的函数
save_checkpoint_to_oss() {
    log "正在保存checkpoint到OSS..."
    
    # 保存到本地
    echo "保存checkpoint时间: $(date)" >> ${CHECKPOINT_DIR}/last_checkpoint_info.txt
    echo "实例ID: $(curl -s http://100.100.100.200/latest/meta-data/instance-id 2>/dev/null || echo 'unknown')" >> ${CHECKPOINT_DIR}/last_checkpoint_info.txt
    
    # 上传到OSS
    if command -v ossutil &> /dev/null; then
        if ossutil cp ${CHECKPOINT_DIR}/ oss://${OSS_BUCKET}/checkpoints/ --recursive --config-file /workspace/.ossutilconfig; then
            log "Checkpoint已成功保存到OSS"
            return 0
        else
            log "错误: 保存checkpoint到OSS失败"
            return 1
        fi
    else
        log "警告: ossutil未安装，无法保存到OSS"
        return 1
    fi
}

# 信号处理函数
handle_interruption() {
    log "收到中断信号，准备保存checkpoint和日志并退出..."
    
    # 强制同步日志到OSS
    sync_logs_to_oss true
    
    if save_checkpoint_to_oss; then
        log "Checkpoint保存成功，准备退出"
    else
        log "Checkpoint保存失败，但仍将退出"
    fi
    
    # 最后一次同步日志
    sync_logs_to_oss true
    
    touch ${SHUTDOWN_FLAG}
    exit 0
}

# 设置信号处理
trap handle_interruption SIGTERM SIGINT

# 主训练循环
train_model() {
    echo "开始模型训练..."
    
    # 这里是实际的训练代码
    # 示例使用Python训练循环
    python3 << EOF
import time
import os

def save_checkpoint(epoch):
    """模拟保存checkpoint"""
    checkpoint_dir = "$CHECKPOINT_DIR"
    with open(os.path.join(checkpoint_dir, f"checkpoint_epoch_{epoch}.txt"), "w") as f:
        f.write(f"Checkpoint for epoch {epoch}\\n")
        f.write(f"Saved at: {time.ctime()}\\n")
    print(f"本地保存checkpoint for epoch {epoch}")

def train():
    """模拟训练过程"""
    start_epoch = 0
    # 检查是否存在之前的训练状态
    checkpoint_info = os.path.join("$CHECKPOINT_DIR", "last_checkpoint_info.txt")
    if os.path.exists(checkpoint_info):
        print("发现之前的训练状态")
        # 实际中应该从checkpoint恢复训练状态
    
    total_epochs = 100
    for epoch in range(start_epoch, total_epochs):
        print(f"开始训练 epoch {epoch+1}/{total_epochs}")
        
        # 模拟训练过程
        time.sleep(10)  # 模拟训练耗时
        
        # 每10个epoch保存一次checkpoint
        if (epoch + 1) % 10 == 0:
            save_checkpoint(epoch+1)
            print("Checkpoint保存到OSS")
            import subprocess
            subprocess.run(["/workspace/save_checkpoint.sh"])
        
        # 检查是否需要退出
        if os.path.exists("$SHUTDOWN_FLAG"):
            print("收到退出信号，结束训练")
            save_checkpoint(epoch+1)  # 保存最后的checkpoint
            break
    
    print("训练完成")

if __name__ == "__main__":
    train()
EOF
    
    echo "模型训练结束"
}

# 监控实例回收的后台进程
monitor_spot_interruption() {
    while true; do
        if check_spot_interruption; then
            log "检测到实例即将被回收，触发保存checkpoint和日志"
            sync_logs_to_oss true  # 强制同步日志
            save_checkpoint_to_oss
            touch ${SHUTDOWN_FLAG}
            exit 0
        fi
        sleep 30  # 每30秒检查一次
    done
}

# 定期同步日志的后台进程
monitor_log_sync() {
    while true; do
        if [ ! -f "${SHUTDOWN_FLAG}" ]; then
            sync_logs_to_oss false  # 定期同步
        else
            break
        fi
        sleep 300  # 每5分钟检查一次
    done
}

# 保存checkpoint的脚本
cat > /workspace/save_checkpoint.sh << 'EOF'
#!/bin/bash
# 保存checkpoint到OSS的脚本

# 日志函数
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a /workspace/logs/training.log
}

WORKSPACE="/workspace"
CHECKPOINT_DIR="${WORKSPACE}/checkpoints"

# 保存到本地
echo "自动保存checkpoint时间: $(date)" >> ${CHECKPOINT_DIR}/last_checkpoint_info.txt

# 上传到OSS
if command -v ossutil &> /dev/null; then
    if ossutil cp ${CHECKPOINT_DIR}/ oss://${OSS_BUCKET}/checkpoints/ --recursive --config-file /workspace/.ossutilconfig; then
        log "Checkpoint已自动保存到OSS"
    else
        log "错误: 自动保存checkpoint到OSS失败"
    fi
else
    log "警告: ossutil未安装，无法保存到OSS"
fi
EOF

chmod +x /workspace/save_checkpoint.sh

# 启动监控进程
monitor_spot_interruption &
MONITOR_PID=$!

# 启动日志同步进程
monitor_log_sync &
LOG_SYNC_PID=$!

log "监控进程已启动 - 实例回收监控PID: $MONITOR_PID, 日志同步PID: $LOG_SYNC_PID"

# 执行训练
train_model

# 等待监控进程结束
kill $MONITOR_PID 2>/dev/null
kill $LOG_SYNC_PID 2>/dev/null

# 训练完成，保存最终checkpoint和日志
save_checkpoint_to_oss
sync_logs_to_oss true  # 最终同步所有日志

log "训练任务完成，正常关机"
# 正常关机 (在实际环境中取消注释)
# shutdown -h now