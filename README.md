# Backup Genius

Backup Genius 是面向 macOS 27 的外置硬盘备份工具。它把 Mac 上一个文件夹的变化单向同步到 APFS 或 exFAT 硬盘，并在硬盘上保留 30 天的旧版。

## 使用

1. 打开 [Backup Genius.app](dist/Backup%20Genius.app)，选择“设置备份…”。
2. 选择源文件夹和硬盘上的目标文件夹。建议为任务建立一个独立文件夹。
3. 保存任务。默认在硬盘连接时自动同步。关掉窗口后，可从菜单栏查看状态。
4. 在“历史版本”中选择文件和恢复位置。恢复会创建新目录，便于比对。

exFAT 上的最新副本是普通文件，可在 Windows 打开。硬盘的 **.backup-genius** 目录保存可移植的版本、校验和恢复记录。“打开已有备份…”可以在没有原 Mac 索引时载入历史。同步完成前请通过应用的“安全推出”释放硬盘。异常拔出后，应用会在重新连接时处理尚未提交的更新。

软件会保留目录中未纳入任务的文件，并提示同名、类型或命名冲突。无法读取的文件、尚未下载的文件和扩展属性超过 2 MiB 的文件会列为“需要处理”。选择本地 APFS 恢复目录可以还原记录的 Mac 文件属性和符号链接。

## 构建与验证

需要 macOS 27 SDK 和 Swift 6.2 或以上。本地包使用临时代码签名和 App Sandbox。

    Scripts/build-app.sh
    Scripts/swift-local.sh test
    Scripts/test-volumes.sh

真实卷测试脚本会创建并挂载两个临时磁盘镜像。测试目录和生成文件独立于现有备份任务。运行基准时可传入文件数量、测试卷目录和 JSON 报告路径。

    Scripts/swift-local.sh build -c release --build-system native --product BackupBench
    .build/release/BackupBench 100000 "/Volumes/Test Drive" "$PWD/Reports/benchmark-local.json"

参见 [性能报告](Reports/Performance.md)。
