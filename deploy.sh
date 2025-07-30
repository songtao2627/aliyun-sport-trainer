#!/bin/bash

# 阿里云抢占式实例ML训练解决方案部署脚本

set -e

echo "=== 阿里云抢占式实例ML训练解决方案部署 ==="

# 配置参数 - 可通过环境变量覆盖
OSS_BUCKET=${OSS_BUCKET:-"your-ml-training-bucket"}
OSS_ENDPOINT=${OSS_ENDPOINT:-"oss-cn-hangzhou.aliyuncs.com"}
SCRIPT_PREFIX=${SCRIPT_PREFIX:-"ml-training-scripts"}

# 检查是否为root用户
if [ "$EUID" -ne 0 ]; then
    echo "请使用root权限运行此脚本: sudo $0"
    exit 1
fi

# 安装基础依赖
echo "安装基础依赖..."
apt update && apt install -y python3-pip curl wget

# 安装Python依赖
echo "安装Python依赖..."
pip3 install -U huggingface_hub datasets torch transformers

# 创建工作目录
WORKSPACE="/workspace"
echo "创建工作目录: $WORKSPACE"
mkdir -p $WORKSPACE
mkdir -p $WORKSPACE/logs

# 下载脚本文件
echo "从OSS下载脚本文件..."
download_script() {
    local script_name=$1
    local target_path=$2
    local oss_url="https://${OSS_BUCKET}.${OSS_ENDPOINT}/${SCRIPT_PREFIX}/${script_name}"
    
    echo "下载 ${script_name}..."
    if curl -sSL "$oss_url" -o "$target_path"; then
        chmod +x "$target_path"
        echo "✓ ${script_name} 下载成功"
    else
        echo "✗ ${script_name} 下载失败，尝试使用本地文件"
        if [ -f "$script_name" ]; then
            cp "$script_name" "$target_path"
            chmod +x "$target_path"
            echo "✓ 使用本地 ${script_name}"
        else
            echo "✗ 本地也未找到 ${script_name}，跳过"
        fi
    fi
}

# 下载所有脚本文件
download_script "prepare_environment.sh" "$WORKSPACE/prepare_environment.sh"
download_script "run_training.sh" "$WORKSPACE/run_training.sh"
download_script "log_manager.sh" "$WORKSPACE/log_manager.sh"
download_script "config.env.example" "$WORKSPACE/config.env.example"

# 下载并安装systemd服务
echo "下载并安装systemd服务..."
if [ -f "/etc/systemd/system/ml-training.service" ]; then
    echo "✓ systemd服务已存在，跳过安装"
else
    service_url="https://${OSS_BUCKET}.${OSS_ENDPOINT}/${SCRIPT_PREFIX}/ml-training.service"
    if curl -sSL "$service_url" -o "/etc/systemd/system/ml-training.service"; then
        echo "✓ ml-training.service 下载并安装成功"
    elif [ -f "ml-training.service" ]; then
        cp ml-training.service /etc/systemd/system/
        echo "✓ 使用本地 ml-training.service"
    else
        echo "✗ 未找到 ml-training.service 文件"
        exit 1
    fi
fi

# 创建配置文件
if [ ! -f "$WORKSPACE/config.env" ] && [ -f "$WORKSPACE/config.env.example" ]; then
    echo "创建默认配置文件..."
    cp "$WORKSPACE/config.env.example" "$WORKSPACE/config.env"
    echo "✓ 已创建 config.env，请根据需要修改配置"
fi

# 重新加载systemd
systemctl daemon-reload

# 启用服务（但不立即启动，让用户先配置）
systemctl enable ml-training.service

echo "=== 部署完成 ==="
echo
echo "✓ 脚本文件已下载到: $WORKSPACE/"
echo "✓ systemd服务已安装并启用"
echo "✓ 基础依赖已安装"
echo
echo "下一步操作:"
echo "1. 编辑配置文件: nano $WORKSPACE/config.env"
echo "2. 修改服务文件中的环境变量: nano /etc/systemd/system/ml-training.service"
echo "3. 启动服务: systemctl start ml-training.service"
echo "4. 查看状态: systemctl status ml-training.service"
echo
echo "服务管理命令:"
echo "- 启动: systemctl start ml-training.service"
echo "- 停止: systemctl stop ml-training.service"
echo "- 重启: systemctl restart ml-training.service"
echo "- 状态: systemctl status ml-training.service"
echo "- 系统日志: journalctl -u ml-training.service -f"
echo
echo "日志管理命令:"
echo "- 查看日志: $WORKSPACE/log_manager.sh view"
echo "- 实时跟踪: $WORKSPACE/log_manager.sh tail"
echo "- 同步到OSS: $WORKSPACE/log_manager.sh sync"
echo "- 日志状态: $WORKSPACE/log_manager.sh status"
echo
echo "环境变量说明:"
echo "可通过以下环境变量自定义OSS配置:"
echo "- OSS_BUCKET: OSS存储桶名称"
echo "- OSS_ENDPOINT: OSS端点地址"
echo "- SCRIPT_PREFIX: OSS中脚本文件的前缀路径"