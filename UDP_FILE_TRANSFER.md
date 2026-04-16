# UDP File Transfer v3

高性能、单向 UDP 文件传输工具，支持大文件传输、内存优化和详细的进度日志。

## 功能特点

### v3 改进 ✨

1. **修复超时问题**
   - 智能超时检测：区分传输完成和真正的超时
   - 传输完成时立即保存文件（不等待超时）
   - 详细的完成度统计

2. **内存优化**
   - 发送端使用固定大小缓冲区，避免重复分配
   - 接收端仅存储去重后的数据块
   - 流式读取文件，不将整个文件加载到内存
   - 支持任意大小文件传输

3. **改进的日志**
   - 实时进度显示（百分比、速度、ETA）
   - 传输统计（吞吐量、重复包数量）
   - 彩色输出和清晰的分段显示
   - 显示缺失的数据块详情

4. **增强的可靠性**
   - CRC32 校验和验证
   - 可配置的重传次数
   - 速率限制选项
   - 重复包检测和统计

## 使用方法

### 编译

```bash
# 编译发送端
go build -o sender_v3 sender_v3.go

# 编译接收端
go build -o receiver_v3 receiver_v3.go

# 或使用 Makefile
make build
```

### 基本用法

1. **启动接收端**

```bash
# 监听默认端口 9999
./receiver_v3

# 指定端口和输出目录
./receiver_v3 -port 9999 -output ./downloads -timeout 30

# 详细日志模式
./receiver_v3 -verbose
```

2. **发送文件**

```bash
# 发送文件到本地
./sender_v3 -file myfile.bin -target localhost:9999

# 发送到远程主机
./sender_v3 -file myfile.bin -target 192.168.1.100:9999

# 自定义参数
./sender_v3 -file bigfile.iso \
  -target 192.168.1.100:9999 \
  -packet-size 1400 \
  -retransmit 3 \
  -rate 5000  # 限速 5MB/s
```

### 参数说明

#### 发送端参数

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `-file` | - | 要发送的文件路径（必需） |
| `-target` | localhost:9999 | 目标地址（host:port） |
| `-packet-size` | 1400 | UDP 数据包大小（字节） |
| `-retransmit` | 3 | 每个数据块的重传次数 |
| `-rate` | 0 | 速率限制（KB/s，0=不限速） |

#### 接收端参数

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `-port` | 9999 | 监听的 UDP 端口 |
| `-output` | ./received | 接收文件的输出目录 |
| `-timeout` | 30 | 超时时间（秒） |
| `-verbose` | false | 详细日志模式 |

## 工作原理

### 协议设计

每个 UDP 包包含 32 字节的头部：

```
[0-15]  文件 ID (MD5 前缀, 16 字节)
[16-19] 总块数 (uint32)
[20-23] 块索引 (uint32)
[24-27] 数据长度 (uint32)
[28-31] 校验和 (uint32)
[32+]   数据
```

### 传输流程

1. **发送端**：
   - 计算文件 ID（基于文件名和大小的 MD5）
   - 将文件分割成固定大小的块
   - 为每个块添加协议头
   - 重复发送每个块 N 次（提高可靠性）
   - 可选的速率限制

2. **接收端**：
   - 监听 UDP 端口
   - 验证每个包的校验和
   - 存储去重后的数据块（节省内存）
   - 实时显示进度和统计
   - 传输完成后按顺序重组文件
   - 智能超时检测

### 可靠性策略

虽然 UDP 不保证可靠传输，但通过以下机制提高成功率：

- **重复发送**：每个块默认发送 3 次
- **校验和**：检测损坏的数据包
- **去重**：避免重复数据占用内存
- **进度追踪**：实时监控传输状态
- **部分保存**：超时时保存已接收的数据

## 示例输出

### 发送端

```
=== UDP File Sender v3 ===
File: ubuntu-22.04.iso
Size: 3.56 GB
File ID: a1b2c3d4e5f6...
Packet size: 1400 bytes (data: 1368 bytes)
Total blocks: 2734695
Retransmit: 3 times per block
Target: 192.168.1.100:9999

Progress: 45.2% | Block 1236543/2734695 | Packets: 3709629 | Throughput: 8234.56 KB/s
Progress: 78.8% | Block 2155223/2734695 | Packets: 6465669 | Throughput: 8156.23 KB/s

=== Transmission Complete ===
Blocks sent: 2734695
Packets sent: 8204085 (x3 retransmit)
Total bytes: 11.49 GB
Duration: 23m 15s
Throughput: 8423.67 KB/s (65.8 Mbps)
```

### 接收端

```
=== UDP File Receiver v3 ===
Listening on port: 9999
Output directory: ./received
Timeout: 30 seconds

[a1b2c3d4] New transfer started: 2734695 blocks expected
[a1b2c3d4] Progress: 23.4% | Blocks: 640000/2734695 | Packets: 1920543 | Duplicates: 5234 | Throughput: 7856.34 KB/s | ETA: 18m 32s
[a1b2c3d4] Progress: 56.7% | Blocks: 1550000/2734695 | Packets: 4651234 | Duplicates: 12456 | Throughput: 8023.45 KB/s | ETA: 9m 12s
[a1b2c3d4] Progress: 89.2% | Blocks: 2440000/2734695 | Packets: 7321987 | Duplicates: 18234 | Throughput: 8156.78 KB/s | ETA: 2m 45s

[a1b2c3d4] Transfer complete! Saving file...
[a1b2c3d4] File saved: ./received/file_a1b2c3d4e5f6.bin

[a1b2c3d4] === File Saved Successfully ===
[a1b2c3d4] Blocks: 2734695/2734695 (100%)
[a1b2c3d4] Packets: 8198765
[a1b2c3d4] Duplicates: 19876
[a1b2c3d4] Duration: 23m 12s
[a1b2c3d4] Throughput: 8234.56 KB/s (64.3 Mbps)
```

## 性能调优

### 网络优化

1. **调整包大小**：
   - 默认 1400 字节适合大多数网络
   - 千兆网络可尝试 8192 字节（jumbo frames）
   - 不稳定网络使用 512-1024 字节

2. **重传次数**：
   - 低丢包率：1-2 次
   - 一般网络：3 次（默认）
   - 高丢包率：5-10 次

3. **速率限制**：
   - 避免网络拥塞
   - 共享网络建议限速
   - 例：`-rate 10000` (10MB/s)

### 系统优化

```bash
# 增加 UDP 接收缓冲区（Linux）
sudo sysctl -w net.core.rmem_max=134217728
sudo sysctl -w net.core.rmem_default=134217728

# 或临时设置
echo 134217728 > /proc/sys/net/core/rmem_max
```

## 限制和注意事项

1. **不保证 100% 可靠**：UDP 本质上不可靠，即使重传也可能丢失数据
2. **单向传输**：接收端不发送确认，发送端无法知道传输是否成功
3. **网络要求**：高丢包率网络（>5%）可能导致大量数据丢失
4. **防火墙**：确保 UDP 端口未被阻止

## 适用场景

✅ **适合**：
- 本地网络文件传输
- 可接受少量数据丢失的场景
- 需要高速度、低延迟的传输
- 广播/组播场景

❌ **不适合**：
- 关键数据传输（使用 TCP）
- 公网传输（丢包率高）
- 需要确认接收的场景

## 故障排除

### 问题：接收端超时但数据未完全接收

**v3 已修复**：现在会显示接收进度和缺失的块。

### 问题：内存占用过高

**v3 已修复**：
- 发送端使用固定缓冲区
- 接收端仅存储去重数据
- 流式文件读取

### 问题：丢包严重

**解决方案**：
1. 增加重传次数：`-retransmit 5`
2. 减小包大小：`-packet-size 512`
3. 添加速率限制：`-rate 5000`
4. 检查网络质量

### 问题：传输速度慢

**解决方案**：
1. 增加包大小：`-packet-size 8192`
2. 减少重传：`-retransmit 2`
3. 移除速率限制
4. 增加系统 UDP 缓冲区

## 版本历史

### v3 (当前版本)
- ✅ 修复超时问题
- ✅ 内存优化
- ✅ 改进的日志和进度显示
- ✅ 增加统计信息

### v2
- 基本的 UDP 文件传输
- 重传机制
- 简单的超时处理

### v1
- 初始实现

## 许可证

MIT License

## 贡献

欢迎提交 Issue 和 Pull Request！
