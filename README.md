# Backup Genius

Backup Genius 将一个源文件夹单向同步到外置硬盘。最新副本保持普通文件结构，替换和删除的文件保留 30 天。Mac 支持 APFS 和 exFAT，Windows 支持 NTFS 和 exFAT。

## 使用

1. 选择“设置备份”，指定源文件夹和外置硬盘上的目标文件夹。每项任务使用独立的目标目录。
2. 保存任务。连接硬盘后应用会自动同步。Mac 菜单栏和 Windows 托盘可查看状态、暂停或推出硬盘。
3. 在“历史版本”选择一个版本和恢复位置。应用在所选位置创建一个新文件夹。
4. 在另一台电脑接上 exFAT 硬盘，选择“打开已有备份”和“预览接管”。首次接管选择空目录。已有源目录的两端变化会先比较和预览，确认冲突的处理方式后才继续自动同步。

应用使用硬盘上的 .backup-genius 目录保存版本、校验和恢复记录。现有 exFAT v1 备份可读，在开始共享写入时升级为 v2。出现未提交的 v1 事务时，先在 Mac 上恢复。v2 事务可由任一端恢复。

特殊文件、冲突名称和权限问题会显示在活动记录。外部新增且未纳入任务的文件保持原样。Windows 保存常用文件属性及符号链接记录，Mac 保存扩展属性和 ACL。跨平台无法还原的项目会标为待处理。

## 构建

Mac 需要 macOS 27 SDK 和 Swift 6.2 或更新版本。构建脚本生成临时签名的 dist/Backup Genius.app。

~~~sh
Scripts/build-app.sh
Scripts/test-volumes.sh
~~~

Windows 使用 Visual Studio 2026（或 Visual Studio 2022 17.14）、C++ 桌面工作负载与 Windows 11 SDK。Windows App SDK 固定为 2.6.5。解压 ZIP 后运行 BackupGenius.exe，依赖保留在同一目录。首版支持 Windows 11 25H2 及之后的版本。

~~~powershell
./Windows/build.ps1 -Architecture x64
./Windows/build.ps1 -Architecture ARM64
./Windows/test-volumes.ps1 -Architecture x64
~~~

Windows 卷测试使用独立的 VHDX。日常备份以普通用户身份运行。卷测试的挂载与格式化步骤需要管理员权限。

## 验证

- [磁盘协议 v2](Protocol/README.md) 描述 Swift 和 C++ 共用的格式和接管规则。
- [Mac 基线性能](Reports/Performance.md) 记录 APFS 与 exFAT 虚拟卷实测。
- [跨平台验证](Reports/Cross-platform.md) 区分本地、GitHub Actions 和实机验证。
- GitHub Actions 构建三套包，交换两个引擎生成的中断事务。版本标签触发预览包和 SHA-256 校验文件发布。

源码使用 [MIT 许可证](LICENSE)。
