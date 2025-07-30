# 阿里云抢占式实例机器学习训练解决方案

## 概述

这是一个专为阿里云抢占式实例设计的机器学习训练解决方案，通过智能监控实例回收信号和自动checkpoint管理，帮助个人开发者以极低成本进行大模型训练。相比按量付费实例，抢占式实例可节省高达90%的成本。

## 核心特性

### 🔄 智能实例回收监控
- 实时监控阿里云元数据服务，提前检测实例回收信号
- 在实例被回收前自动保存训练状态
- 支持优雅退出，确保数据完整性

### 💾 自动Checkpoint管理
- 定期自动保存训练checkpoint到阿里云OSS
- 实例重启后自动恢复最新训练状态
- 支持断点续训，训练进度永不丢失

### 📋 日志持久化
- 自动同步训练日志到OSS，防止实例回收导致日志丢失
- 支持历史日志查看和下载
- 提供完整的日志管理工具

### 🚀 一键部署
- 基于systemd服务管理，开机自动启动
- 完整的环境准备和依赖安装
- 详细的日志记录和错误处理

### 📊 成本优化
- 充分利用抢占式实例的价格优势
- 智能资源管理，避免不必要的计算浪费
- 适合长时间训练任务的成本控制

## 文件结构

```
├── ml-training.service      # systemd服务配置文件
├── prepare_environment.sh   # 环境准备脚本
├── run_training.sh         # 主训练脚本
├── log_manager.sh          # 日志管理脚本
├── deploy.sh               # 一键部署脚本
├── config.env.example      # 配置文件模板
└── readme.md              # 项目文档
```

## 快速开始

### 1. 环境要求

- 阿里云抢占式ECS实例（推荐GPU实例）
- Ubuntu 18.04+ 或 CentOS 7+
- 已配置阿里云OSS存储桶

### 2. 部署方式

⚠️ **关键概念**：抢占式实例的本地NVMe是临时盘，关机后会被清空。因此脚本和服务配置必须通过自动化方式部署。

#### 推荐方式：Cloud-Init自动部署

1. **上传脚本到OSS**：
   ```bash
   # 将所有脚本文件上传到OSS存储桶
   ossutil cp *.sh oss://your-bucket/ml-training-scripts/
   ossutil cp ml-training.service oss://your-bucket/ml-training-scripts/
   ossutil cp config.env.example oss://your-bucket/ml-training-scripts/
   ```

2. **创建抢占式实例**：
   在"高级选项 → 用户数据"中填入：
   ```yaml
   #cloud-config
   runcmd:
     - export OSS_BUCKET=your-bucket-name
     - export OSS_ENDPOINT=oss-cn-hangzhou.aliyuncs.com
     - curl -sSL https://your-bucket.oss-cn-hangzhou.aliyuncs.com/ml-training-scripts/deploy.sh | bash
     - systemctl start ml-training.service
   ```

3. **自动化流程**：
   - 实例启动后自动下载并执行deploy.sh
   - 自动安装依赖、下载脚本、配置服务
   - 自动启动训练服务

> 💡 **提示**：如果需要更快的启动速度，也可以先在按量实例上运行deploy.sh，然后制作自定义镜像使用。

### 3. 配置参数

编辑 `ml-training.service` 文件，修改以下环境变量：

```bash
Environment=ALIBABA_CLOUD_ACCESS_KEY_ID=你的AccessKey
Environment=ALIBABA_CLOUD_ACCESS_KEY_SECRET=你的AccessSecret
Environment=OSS_ENDPOINT=oss-cn-hangzhou.aliyuncs.com
Environment=OSS_BUCKET=你的OSS存储桶名称
```

### 4. 监控训练进度

```bash
# 查看训练日志
./log_manager.sh view

# 实时跟踪日志
./log_manager.sh tail

# 查看服务日志
journalctl -u ml-training.service -f

# 查看checkpoint状态
ls -la /workspace/checkpoints/

# 查看日志状态
./log_manager.sh status
```

## 工作原理

### 存储架构设计

```
抢占式实例存储分层：
├── 系统盘/镜像（持久化）
│   ├── 脚本文件（/home/ubuntu/*.sh）
│   ├── systemd服务（/etc/systemd/system/）
│   └── 系统依赖和环境
├── 本地NVMe（临时盘，关机清空）
│   ├── /workspace/logs/（训练日志）
│   ├── /workspace/checkpoints/（模型权重）
│   └── /workspace/cache/（临时缓存）
└── 阿里云OSS（永久存储）
    ├── logs/{instance-id}/{date}/
    └── checkpoints/{model-name}/
```

### 实例回收监控机制

脚本通过查询阿里云元数据服务 `http://100.100.100.200/latest/meta-data/instance/spot/termination-time` 来检测实例是否即将被回收。当检测到回收信号时，会立即触发checkpoint保存流程。

### Checkpoint管理流程

1. **定期保存**: 训练过程中每N个epoch自动保存checkpoint到本地NVMe
2. **实时同步**: 自动上传checkpoint到阿里云OSS
3. **紧急保存**: 检测到实例回收信号时立即保存并强制同步
4. **状态恢复**: 新实例启动时自动从OSS下载最新checkpoint

### 服务生命周期

```
实例启动 → systemd自启动 → 环境准备 → 恢复checkpoint → 开始训练 → 监控回收信号 → 保存状态 → 优雅退出
```

**关键设计原则**：
- **脚本/服务** → 放在系统盘，实例重启后依然存在
- **训练数据** → 实时同步到OSS，本地NVMe只作高速缓存
- **日志文件** → 定期上传OSS，支持历史查看和恢复

## 日志管理

### 日志持久化机制

由于抢占式实例可能随时被回收，本解决方案实现了完整的日志持久化机制：

- **自动同步**: 每5分钟自动将日志同步到OSS
- **强制同步**: 在实例回收前强制同步所有日志
- **历史恢复**: 新实例启动时自动恢复最近3天的历史日志
- **分类存储**: 按实例ID和日期分类存储日志

### 日志管理命令

```bash
# 查看最近的训练日志
./log_manager.sh view 100

# 实时跟踪日志
./log_manager.sh tail

# 立即同步日志到OSS
./log_manager.sh sync

# 下载指定日期的日志
./log_manager.sh download 2024-01-15

# 列出OSS中的所有日志
./log_manager.sh list

# 清理本地历史日志
./log_manager.sh clean

# 查看日志状态
./log_manager.sh status
```

### OSS日志结构

```
your-bucket/
└── logs/
    └── {instance-id}/
        ├── 2024-01-15/
        │   ├── training.log
        │   ├── prepare.log
        │   └── service.log
        ├── 2024-01-16/
        └── ...
```

## 自定义训练代码

在 `run_training.sh` 中的 `train_model()` 函数内替换示例代码为你的实际训练逻辑：

```python
# 替换这部分为你的训练代码
def train():
    # 你的模型初始化代码
    model = YourModel()
    
    # 检查并加载checkpoint
    if os.path.exists(checkpoint_path):
        model.load_state_dict(torch.load(checkpoint_path))
    
    # 训练循环
    for epoch in range(start_epoch, total_epochs):
        # 你的训练逻辑
        train_one_epoch(model)
        
        # 定期保存checkpoint
        if epoch % save_interval == 0:
            torch.save(model.state_dict(), checkpoint_path)
```

## 最佳实践

### 成本优化建议

1. **选择合适的实例规格**: 根据模型大小选择GPU实例
2. **设置合理的保存频率**: 平衡性能和数据安全
3. **使用多可用区**: 提高实例获取成功率
4. **监控训练效率**: 及时调整超参数

### 安全建议

1. **使用RAM角色**: 避免在代码中硬编码AccessKey
2. **OSS权限控制**: 仅授予必要的读写权限
3. **网络安全组**: 限制不必要的网络访问
4. **定期备份**: 重要数据多重备份

## 故障排除

### 常见问题

**Q: 服务启动失败**
```bash
# 检查服务状态
sudo systemctl status ml-training.service
# 查看详细日志
journalctl -u ml-training.service -n 50
```

**Q: OSS上传失败**
```bash
# 检查ossutil配置
ossutil config --config-file /workspace/.ossutilconfig
# 测试OSS连接
ossutil ls oss://your-bucket/ --config-file /workspace/.ossutilconfig
```

**Q: 实例回收检测不工作**
```bash
# 手动测试元数据服务
curl -s http://100.100.100.200/latest/meta-data/instance/spot/termination-time
```

## 贡献

欢迎提交Issue和Pull Request来改进这个解决方案。

## 许可证

MIT License

---

**注意**: 使用抢占式实例时，请确保你的训练任务能够容忍中断，并且已经做好了充分的数据备份。