# Backup Genius

Backup Genius 将电脑上的文件夹单向同步到外置硬盘。一个 BackupGenius 主目录可以管理多个源文件夹，最新副本保持普通文件结构，替换和删除的文件保留 30 天。Mac 支持 APFS 和 exFAT，Windows 支持 NTFS 和 exFAT。

## 使用

1. 打开“新手引导”，选择外置硬盘根目录，确认硬盘上的 BackupGenius 主目录，然后添加一个或多个源文件夹。
2. 检查映射后开始备份。子文件夹与源文件夹同名。同名来源会按父目录分组，例如 Work/Projects 和 Personal/Projects，预览中可更改分组名称。
3. 默认开启连接后自动备份、全部完成后自动推出和旧版保留 30 天。登录启动可在引导中开启。首次使用也可取消引导，随后从菜单重新打开。
4. 通过“所属文件夹”选择任务，查看活动和历史、筛选新增与修改，或恢复到指定位置。某个源文件夹出错时，其他文件夹继续备份，硬盘会保留连接以便处理问题。
5. 在另一台电脑接上 exFAT 硬盘，选择“打开已有备份”，打开 BackupGenius 主目录。逐个文件夹预览并接管。首次接管选择空目录，已有源目录的两端变化会先比较和预览，确认冲突的处理方式后继续自动同步。

硬盘改名后，应用用卷标识和任务 ID 找回原备份。新任务使用集合布局 2，BackupGenius 主目录只保存一个隐藏的 `.backup-genius.json` 应用识别文件。每个子目录的索引身份、历史版本和恢复记录位于同卷根目录隐藏的 `.backup-genius-data/<任务 UUID>` 中。源文件夹改名后，应用验证其原生身份并移动对应备份目录，沿用原任务和历史。在 exFAT 上，macOS 可能生成隐藏的 `._` 系统元数据。

单任务布局与集合布局均按各自的识别文件加载。旧布局的 Mac 任务可在设置中选择“整理备份目录…”并授权硬盘根目录。两台电脑都需要使用支持对应目录布局的版本。现有 exFAT v1 备份可读，在开始共享写入时升级为 v2。出现未提交的 v1 事务时，先在 Mac 上恢复。v2 事务可由任一端恢复。

引擎分别识别源盘和备份盘的 HDD、SSD 类型。HDD 和未知设备采用单路准备、4 MiB 顺序窗口，双端 SSD 最多使用四路准备和 1 MiB 窗口。哈希块保持 64 KiB，相邻变化块合并写入，小文件以 128 项批次提交。所有任务共用串行磁盘处理队列，内容缓冲区预算限制为 64 MiB。USB 桥接器未报告类型时，可在高级设置中为源盘或备份盘指定 HDD、SSD，设置按本机卷标识保存。

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
- [Mac 性能报告](Reports/Performance.md) 记录 APFS 与 exFAT 的 10 万小文件虚拟卷实测。
- [跨平台验证](Reports/Cross-platform.md) 区分本地、GitHub Actions 和实机验证。
- GitHub Actions 构建三套包，交换两个引擎生成的中断事务。版本标签触发预览包和 SHA-256 校验文件发布。

源码使用 [MIT 许可证](LICENSE)。
