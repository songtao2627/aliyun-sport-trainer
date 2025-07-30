#!/bin/bash

# ML训练环境准备脚本
# 该脚本负责下载数据集、模型，并从OSS恢复最新的checkpoint

set -e

# 日志函数
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a /workspace/logs/prepare.log
}

log "开始准备训练环境..."

# 定义变量
WORKSPACE="/workspace"
DATA_DIR="${WORKSPACE}/data"
MODEL_DIR="${WORKSPACE}/models"
CHECKPOINT_DIR="${WORKSPACE}/checkpoints"
LOG_DIR="${WORKSPACE}/logs"

# 创建必要的目录
mkdir -p ${DATA_DIR}
mkdir -p ${MODEL_DIR}
mkdir -p ${CHECKPOINT_DIR}
mkdir -p ${LOG_DIR}

# 检查必要的环境变量
if [[ -z "${OSS_ENDPOINT}" || -z "${OSS_BUCKET}" ]]; then
    log "错误: OSS配置环境变量未设置"
    exit 1
fi

# 安装必要的工具
log "更新系统包..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq

log "安装必要工具..."
apt-get install -y -qq wget curl unzip python3 python3-pip

# 安装Python依赖
log "安装Python依赖..."
pip3 install --quiet torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cpu

# 安装ossutil用于与阿里云OSS交互
log "安装ossutil..."
if [ ! -f /usr/local/bin/ossutil ]; then
    wget -q http://gosspublic.alicdn.com/ossutil/1.7.7/ossutil64 -O /usr/local/bin/ossutil
    chmod +x /usr/local/bin/ossutil
    log "ossutil安装完成"
else
    log "ossutil已存在，跳过安装"
fi

# 配置ossutil
log "配置ossutil..."
ossutil config -e ${OSS_ENDPOINT} -i ${ALIBABA_CLOUD_ACCESS_KEY_ID} -k ${ALIBABA_CLOUD_ACCESS_KEY_SECRET} -L CH --config-file /workspace/.ossutilconfig

# 从OSS恢复最新的checkpoint（如果存在）
log "检查并恢复OSS中的checkpoint..."
if ossutil ls oss://${OSS_BUCKET}/checkpoints/ --config-file /workspace/.ossutilconfig > /dev/null 2>&1; then
    log "发现OSS中的checkpoint，开始恢复..."
    ossutil cp oss://${OSS_BUCKET}/checkpoints/ ${CHECKPOINT_DIR}/ --recursive --config-file /workspace/.ossutilconfig
    log "Checkpoint恢复完成"
else
    log "OSS中未发现checkpoint，将从头开始训练"
fi

# 从OSS恢复历史日志（可选）
log "检查并恢复OSS中的历史日志..."
instance_id=$(curl -s http://100.100.100.200/latest/meta-data/instance-id 2>/dev/null || echo 'unknown')
if ossutil ls oss://${OSS_BUCKET}/logs/ --config-file /workspace/.ossutilconfig > /dev/null 2>&1; then
    log "发现OSS中的历史日志，开始恢复最近3天的日志..."
    
    # 恢复最近3天的日志
    for i in {0..2}; do
        date_str=$(date -d "-${i} days" '+%Y-%m-%d' 2>/dev/null || date -v-${i}d '+%Y-%m-%d' 2>/dev/null || echo $(date '+%Y-%m-%d'))
        log_path="oss://${OSS_BUCKET}/logs/${instance_id}/${date_str}/"
        
        if ossutil ls "$log_path" --config-file /workspace/.ossutilconfig > /dev/null 2>&1; then
            mkdir -p "${LOG_DIR}/history/${date_str}"
            ossutil cp "$log_path" "${LOG_DIR}/history/${date_str}/" --recursive --config-file /workspace/.ossutilconfig
            log "恢复了 ${date_str} 的历史日志"
        fi
    done
else
    log "OSS中未发现历史日志"
fi

# 下载数据集（示例）
log "准备数据集..."
# 这里可以添加你的数据集下载逻辑
# 例如：wget -O ${DATA_DIR}/dataset.zip https://your-dataset-url.com/dataset.zip

log "环境准备完成"