# Backup Genius 性能报告

## 1.5.0 的完整时间点

加入独立时间点后的实测与资源开销见 [1.5.0 验证报告](Resident-and-restore-points.md#performance-on-virtual-volumes)。本轮完成 APFS 10 万小文件和 exFAT 1 千小文件测试；两组无变化时正文读写均为零。初次归档和变化后的时间点元数据处理带来额外开销，不能沿用下方 1.3.0 的耗时作为新版结果。

## 1.3.0 的 10 万小文件测试

在 Apple Silicon、macOS 27.2 上使用 Release 备份引擎和实际 FSEvents，目标为挂载的 APFS 和 exFAT 稀疏磁盘镜像。两组各有 100,000 个 1 KiB 文件及一个 32 MiB 文件。修改与批量移动各涉及 1,000 个小文件。两组全部完成，问题数为零。

| 格式 | 场景 | 检查耗时 | 总耗时 | 源正文读取 | 目标正文读取 | 最新副本写入 | 历史写入 |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| APFS | 首次备份 | 1.215 s | 89.412 s | 129.656 MiB | 0 B | 129.656 MiB | 0 B |
| APFS | 无变化 | 0.197 ms | 30.706 ms | 0 B | 0 B | 0 B | 0 B |
| APFS | 修改 1% | 77.720 ms | 2.406 s | 1,024,000 B | 0 B | 1,024,000 B | 0 B |
| APFS | 批量移动 | 169.046 ms | 1.059 s | 0 B | 0 B | 0 B | 0 B |
| APFS | 大文件改一个字节 | 1.569 ms | 0.137 s | 32 MiB | 0 B | 64 KiB | 0 B |
| exFAT | 首次备份 | 1.100 s | 3,838.159 s | 129.656 MiB | 0 B | 129.656 MiB | 0 B |
| exFAT | 无变化 | 0.180 ms | 28.988 ms | 0 B | 0 B | 0 B | 0 B |
| exFAT | 修改 1% | 91.289 ms | 3.124 s | 1,024,000 B | 1,024,000 B | 1,024,000 B | 1,024,000 B |
| exFAT | 批量移动 | 244.812 ms | 9.462 s | 0 B | 0 B | 0 B | 0 B |
| exFAT | 大文件改一个字节 | 0.657 ms | 0.218 s | 32 MiB | 32 MiB | 64 KiB | 32 MiB |

无变化时，两组都检查了 0 个候选条目。单块更新使用 32 次 1 MiB 的源读取请求，比对 512 个 64 KiB 校验块，然后向最新副本写入一个块。exFAT 首次保存该文件的旧版另外读取并归档完整的 32 MiB。两组的内容缓冲区预算均为 24 MiB。

exFAT 首次备份耗时约 64 分钟。运行中采样观察到暂存文件创建、重命名、修改时间设置和落盘占用较多时间。测试卷的分配单元为 32 KiB，macOS 还为这些文件生成了 AppleDouble 元数据。最初的 2 GiB 镜像空间耗尽，以上数据来自 8 GiB 镜像的完整重跑。表中的字节数为应用统计的正文数据。日志、文件系统分配及系统元数据另占空间。

这些数字来自磁盘镜像。USB HDD、SSD 实机及完整 Windows 应用的验证状态见 [跨平台验证](Cross-platform.md)。

[APFS 原始数据](benchmark-1.3-apfs.json) · [exFAT 原始数据](benchmark-1.3-exfat.json)

以下命令在独立的测试镜像上复现工作负载，原始测量以 JSON 输出。

~~~sh
Scripts/swift-local.sh build -c release --build-system native --product BackupBench
export BACKUP_GENIUS_BENCH_BIN="$(Scripts/swift-local.sh build -c release --build-system native --show-bin-path)/BackupBench"
BACKUP_GENIUS_TEST_VOLUME_SIZE=8g Scripts/test-volumes.sh -- /bin/zsh -c '
set -e
"$BACKUP_GENIUS_BENCH_BIN" 100000 "$BACKUP_GENIUS_TEST_APFS"
"$BACKUP_GENIUS_BENCH_BIN" 100000 "$BACKUP_GENIUS_TEST_EXFAT"
'
~~~

## 1.2 基线

实测环境为 Apple Silicon、macOS 27.2 和挂载的 APFS、exFAT 稀疏磁盘镜像。Release 引擎通过实际 FSEvents 通知检查工作区中的文件。APFS 使用 100,000 个小文件，exFAT 使用 10,000 个小文件。每个小文件为 1 KiB，另外放置一个 32 MiB 文件。修改和移动分别涉及 1% 的小文件。

| 测试 | APFS 耗时 | exFAT 耗时 | APFS 最新副本写入 | exFAT 最新副本写入 |
| --- | ---: | ---: | ---: | ---: |
| 首次备份 | 94.177 s | 52.043 s | 129.656 MiB | 41.766 MiB |
| 无变化 | 0.032 s | 0.003 s | 0 B | 0 B |
| 修改 1% | 2.355 s | 0.215 s | 1,024,000 B | 102,400 B |
| 批量移动 | 1.042 s | 0.312 s | 0 B | 0 B |
| 大文件改一个字节 | 0.127 s | 0.172 s | 64 KiB | 64 KiB |

无变化的两次运行都检查了 0 个文件条目，正文读取、写入和历史归档均为 0。修改 1% 时，分别检查 1,000 和 100 个文件条目。批量移动直接改路径，两次正文读取量也都是 0。

大文件测试读取源文件的 32 MiB 来确定变化块。exFAT 第一次保留这个文件的旧版时，另外读取并写入 32 MiB 历史数据。此后可复用已归档的块。APFS 同卷克隆在这个测试中没有历史正文写入。

耗时涵盖候选检查、文件处理和提交。它从处理文件事件队列后开始计时，不包含卷挂载和事件传递的等待。写入量是应用统计的文件数据，不包含 SQLite、提交记录、文件系统元数据和硬件写放大。镜像测量可用于复验读写行为，外接硬盘耗时随设备和文件系统而变化。

[APFS 原始数据](benchmark-apfs.json) · [exFAT 原始数据](benchmark-exfat.json)
