# UDP 文件传输 v3 - 快速开始

## 🚀 5分钟快速上手

### 1. 编译程序

```bash
# 编译发送端和接收端
go build -o sender_v3 sender_v3.go
go build -o receiver_v3 receiver_v3.go
```

### 2. 启动接收端

在一个终端窗口运行：

```bash
./receiver_v3
```

你会看到：
```
=== UDP File Receiver v3 ===
Listening on port: 9999
Output directory: ./received
Timeout: 30 seconds
Verbose: false

Waiting for packets...
```

### 3. 发送文件

在另一个终端窗口运行：

```bash
./sender_v3 -file myfile.bin -target localhost:9999
```

## 📊 实际使用示例

### 示例 1：本地传输 100MB 文件

```bash
# 创建测试文件
dd if=/dev/urandom of=test_100mb.bin bs=1M count=100

# 终端 1
./receiver_v3 -output ./downloads

# 终端 2
./sender_v3 -file test_100mb.bin -target localhost:9999
```

**预期输出（发送端）**：
```
=== UDP File Sender v3 ===
File: test_100mb.bin
Size: 100.00 MB
File ID: a1b2c3d4e5f6...
Packet size: 1400 bytes (data: 1368 bytes)
Total blocks: 76628
Retransmit: 3 times per block
Target: localhost:9999

Progress: 25.3% | Block 19380/76628 | Packets: 58140 | Throughput: 8234.56 KB/s
Progress: 52.7% | Block 40374/76628 | Packets: 121122 | Throughput: 8156.23 KB/s
Progress: 78.4% | Block 60076/76628 | Packets: 180228 | Throughput: 8089.12 KB/s

=== Transmission Complete ===
Blocks sent: 76628
Packets sent: 229884 (x3 retransmit)
Total bytes: 321.62 MB
Duration: 12.456s
Throughput: 8423.67 KB/s (65.8 Mbps)
```

**预期输出（接收端）**：
```
[a1b2c3d4] New transfer started: 76628 blocks expected
[a1b2c3d4] Progress: 34.2% | Blocks: 26198/76628 | Packets: 78594 | Duplicates: 234 | Throughput: 7856.34 KB/s | ETA: 8s
[a1b2c3d4] Progress: 67.8% | Blocks: 51942/76628 | Packets: 155826 | Duplicates: 487 | Throughput: 8023.45 KB/s | ETA: 4s
[a1b2c3d4] Progress: 100.0% | Blocks: 76628/76628 | Packets: 229884 | Duplicates: 723 | Throughput: 8156.78 KB/s | ETA: 0s

[a1b2c3d4] Transfer complete! Saving file...
[a1b2c3d4] File saved: ./downloads/file_a1b2c3d4e5f6.bin

[a1b2c3d4] === File Saved Successfully ===
[a1b2c3d4] Blocks: 76628/76628 (100%)
[a1b2c3d4] Packets: 229884
[a1b2c3d4] Duplicates: 723
[a1b2c3d4] Duration: 12.345s
[a1b2c3d4] Throughput: 8234.56 KB/s (64.3 Mbps)
```

### 示例 2：远程传输大文件（限速）

```bash
# 接收端（远程服务器 192.168.1.100）
./receiver_v3 -port 9999 -output /data/incoming -timeout 60

# 发送端（本地）
./sender_v3 -file bigfile.iso \
  -target 192.168.1.100:9999 \
  -packet-size 1400 \
  -retransmit 3 \
  -rate 10000  # 限速 10MB/s
```

### 示例 3：不稳定网络（高重传）

```bash
# 接收端
./receiver_v3 -timeout 60

# 发送端：小包 + 高重传
./sender_v3 -file important.zip \
  -target host:9999 \
  -packet-size 512 \
  -retransmit 5
```

## 🎯 常见场景配置

### 千兆局域网（追求速度）
```bash
# 发送端
./sender_v3 -file myfile.bin \
  -packet-size 8192 \
  -retransmit 2 \
  -target host:9999
```

### WiFi 环境（平衡）
```bash
# 发送端（默认配置最适合）
./sender_v3 -file myfile.bin -target host:9999
```

### 公网传输（高可靠）
```bash
# 接收端
./receiver_v3 -timeout 120

# 发送端
./sender_v3 -file myfile.bin \
  -packet-size 512 \
  -retransmit 5 \
  -rate 1000 \
  -target host:9999
```

### 共享网络（限速）
```bash
# 发送端：限速 5MB/s
./sender_v3 -file myfile.bin \
  -rate 5000 \
  -target host:9999
```

## 🔧 常见问题解决

### Q1: 接收端显示超时，但接收了很多数据

**A**: v3 已修复此问题！现在会显示：
- 如果接收完整：立即保存并显示"File Saved Successfully"
- 如果真的超时：显示"Transfer Timeout"和缺失的块编号

### Q2: 内存占用太高

**A**: v3 已优化内存使用：
- 发送端：< 10MB（使用固定缓冲区）
- 接收端：约为文件大小（去重存储）

如果仍然内存紧张，可以：
- 分多次传输小文件
- 增加系统 swap
- 传输完成后内存会自动释放

### Q3: 传输速度慢

**解决方案**：
```bash
# 1. 增加包大小（需要支持 jumbo frames）
./sender_v3 -file myfile.bin -packet-size 8192

# 2. 减少重传次数（稳定网络）
./sender_v3 -file myfile.bin -retransmit 2

# 3. 检查网络带宽
# 4. 增加系统 UDP 缓冲区（Linux）
sudo sysctl -w net.core.rmem_max=134217728
```

### Q4: 丢包很多

**解决方案**：
```bash
# 1. 增加重传次数
./sender_v3 -file myfile.bin -retransmit 5

# 2. 减小包大小
./sender_v3 -file myfile.bin -packet-size 512

# 3. 添加速率限制
./sender_v3 -file myfile.bin -rate 5000

# 4. 检查网络质量
ping -c 100 target_host  # 查看丢包率
```

### Q5: 文件不完整

查看接收端日志，会显示缺失的块：
```
[a1b2c3d4] Missing blocks: [123, 456, 789, ...] (showing first 20)
[a1b2c3d4] incomplete file: 42 blocks missing
```

**解决方案**：
- 增加重传次数：`-retransmit 5`
- 增加超时时间：`-timeout 60`
- 改善网络质量

## 📝 命令行参数速查

### 发送端 (sender_v3)

```
-file string          要发送的文件路径（必需）
-target string        目标地址 host:port（默认 localhost:9999）
-packet-size int      UDP 包大小（默认 1400）
-retransmit int       重传次数（默认 3）
-rate int             速率限制 KB/s（0=不限速）
```

### 接收端 (receiver_v3)

```
-port int             监听端口（默认 9999）
-output string        输出目录（默认 ./received）
-timeout int          超时秒数（默认 30）
-verbose              详细日志模式
```

## 🎓 性能调优建议

| 网络环境 | packet-size | retransmit | rate | timeout |
|----------|-------------|------------|------|---------|
| 千兆局域网 | 8192 | 2 | 0 | 30 |
| 百兆局域网 | 1400 | 3 | 0 | 30 |
| WiFi | 1400 | 3 | 0 | 60 |
| 4G/5G | 1024 | 4 | 5000 | 90 |
| 公网 | 512 | 5 | 2000 | 120 |

## 📚 更多文档

- 完整使用文档：`UDP_FILE_TRANSFER.md`
- v3 改进说明：`UDP_V3_IMPROVEMENTS.md`
- 构建说明：`Makefile.udp`

## ⚠️ 注意事项

1. **UDP 不保证可靠传输**：即使重传，仍可能丢失数据
2. **防火墙设置**：确保 UDP 端口未被阻止
3. **网络质量**：高丢包率（>5%）可能导致传输失败
4. **适用场景**：最适合局域网环境，不推荐用于互联网关键数据传输

## 🆘 获取帮助

```bash
# 查看帮助
./sender_v3 -help
./receiver_v3 -help

# 查看版本日志
git log --oneline sender_v3.go receiver_v3.go
```

---

**快速测试**：
```bash
# 一键测试（需要 Go 环境）
go build -o sender_v3 sender_v3.go && \
go build -o receiver_v3 receiver_v3.go && \
echo "创建测试文件..." && \
dd if=/dev/urandom of=test.bin bs=1M count=10 2>/dev/null && \
echo "启动接收端（后台）..." && \
./receiver_v3 &
RECEIVER_PID=$! && \
sleep 2 && \
echo "发送文件..." && \
./sender_v3 -file test.bin && \
sleep 2 && \
kill $RECEIVER_PID && \
echo "检查接收的文件..." && \
ls -lh received/
```
