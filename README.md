# Backup Genius

Backup Genius 将一个源文件夹单向同步到外置硬盘。最新副本保持普通文件结构，替换和删除的文件保留 30 天。Mac 支持 APFS 和 exFAT，Windows 支持 NTFS 和 exFAT。

## 使用

1. 选择“设置备份”，指定源文件夹和外置硬盘上的目标子文件夹。Mac 会请你选择一次硬盘根目录，以便在目标文件夹之外保存恢复记录。
2. 保存任务。启用自动同步后，应用识别到指定硬盘就开始备份。Mac 设置中的“备份完成后自动推出硬盘”可在成功同步后安全推出。
3. Mac 的“备份历史”按轮次列出新增和修改的文件，支持按类型和路径搜索，推出硬盘后仍可查看。需要恢复时切换到“历史版本”，选择版本和恢复位置。
4. 在另一台电脑接上 exFAT 硬盘，选择“打开已有备份”和“预览接管”。首次接管选择空目录。已有源目录的两端变化会先比较和预览，确认冲突的处理方式后才继续自动同步。

硬盘改名后，应用用卷标识和任务 ID 找回原备份。新备份在目标文件夹内保存一个隐藏的 `.backup-genius.json` 识别文件，历史版本和恢复记录保存在同一硬盘根目录下隐藏的 `.backup-genius-data` 中。在 exFAT 上，macOS 可能还会生成隐藏的 `._` 系统元数据。已有 Mac 任务可在设置中选择“整理备份目录…”并授权硬盘根目录。两台电脑都需要使用支持该目录布局的版本。现有 exFAT v1 备份可读，在开始共享写入时升级为 v2。出现未提交的 v1 事务时，先在 Mac 上恢复。v2 事务可由任一端恢复。

特殊文件、冲突名称和权限问题会显示在活动记录。外部新增且未纳入任务的文件保持原样。Windows 保存常用文件属性及符号链接记录，Mac 保存扩展属性和 ACL。跨平台无法还原的项目会标为待处理。

Mac 同步会跳过 Swift 工程的 `.build` 缓存和 Backup Genius 项目自己生成的安装包。原先由应用备份的安装包在下一次同步时从最新副本移入历史。备份设置中的「目标中已有同名文件」可选「按 Mac 源文件同步」。应用首次用块校验值比较同名普通文件。内容一致的直接沿用，有差异的仅更新变化块，硬盘上的原版保留 30 天。只存在于硬盘上的文件继续保留。

Mac 备份按原名保留 macOS 可写入 exFAT 的文件和文件夹。需要在 Mac 打开或恢复的名称会在活动记录中注明。已有符号链接按链接指向比较，链接目标写入备份记录，可在 Mac 还原。Windows 保留它无法表示的项目。若中断的事务包含 Mac 专用名称或实际的 Mac 符号链接，请接回 Mac 恢复后再切换电脑。

每轮备份记录从 Mac 1.1.0 开始保存。完成时间、结果和无变化的轮次保存在这台 Mac 的索引里。硬盘提交记录会标记新增和修改属于哪一轮，本机索引重建时可恢复已提交的文件清单。

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
