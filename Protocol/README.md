# Backup Genius 磁盘协议 v2

共享格式用于 exFAT。Windows NTFS 使用相同的 v2 日志格式。Mac APFS 使用 v1 和同卷克隆。

## 位置和编码

| 记录目录内的路径 | 内容 |
| --- | --- |
| job.json | 任务标记，含 version、job、format、legacyGeneration 和可选 initialWriter |
| lock | 进程租约文件，Mac 用 flock，Windows 用 LockFileEx |
| journal/00000000000000000001.json | 从 1 开始的 20 位十进制提交代次 |
| journal/pending.json | 同一格式的准备记录 |
| packs/\<UUID\> | 归档块的原始字节 |
| stage/\<UUID\> | 待发布的文件或临时移动位置 |

原有布局的记录目录为备份文件夹中的 `.backup-genius`。新布局将记录目录放在卷根目录的 `.backup-genius-data/<任务 UUID>`。备份文件夹中的隐藏识别文件 `.backup-genius.json` 记录整数 layout（目前为 1）、任务 UUID job、文件系统 format 及卷内相对路径 folder。识别文件须与记录目录内的任务标记匹配。卷标名称和挂载点不参与匹配。

整理现有备份时，持锁恢复未完成的事务，发布识别文件，然后在同卷移动记录目录。移动前可从原位置读到同一任务，移动后使用新位置。日志内容和代次沿用原值。

## 多文件夹集合布局 2

新集合固定使用卷根目录的 `BackupGenius` 主目录。其 `.backup-genius.json` 是普通 UTF-8 JSON，包含 layout 为 2、集合 UUID id、format、64 位 revision 和 mappings 数组。每个映射包含映射 UUID id、任务 UUID job、相对目录 folder 及布尔 enabled。folder 为原源目录名，或一层来源分组加原目录名。不同映射的目录不得重叠，大小写规则按目标卷判断。

集合子目录沿用上述逐任务日志，控制文件重定向至 `/.backup-genius-data/<任务 UUID>`。Mac APFS 成员使用 v1，Mac exFAT 和 Windows 成员使用 v2。来源路径、授权、主机卷标识和事件游标保存在本机。禁用映射保留其最新副本和历史。

每个进程在连接期间持有 `/.backup-genius-data/set/lock` 的系统文件锁。映射新增、分组和源目录改名使用 `set/pending.json`，其外层与提交记录使用相同的 Base64 原始字节和 SHA-256 封装。内层包含旧代次 base、新完整配置 next、新任务标记 additions，以及含 from、to、job 的 moves。应用先将准备记录落盘，再移动目录、初始化成员记录，最后原子发布新主目录标记并落盘。

目录移动先进入 `set/<任务 UUID>` 暂存位置。移动期间的目录内带有临时 `.backup-genius.json` 见证记录，包含 job 和目标 revision。恢复时验证见证记录，并将目录继续移动至已准备的新位置。主目录标记发布后删除见证记录及准备记录。恢复可重复执行，已发布代次可完成清理。跨端通过相同字段完成恢复。设置提交成功后，子目录中只保留普通备份内容。

本机在集合事务前持久保存待创建的任务配置，磁盘恢复后再幂等完成本机登记。所有同盘映射在事务边界依次运行，全部启用且需要同步的任务成功、事件队列排空后才可自动推出。任一任务失败会保留其原副本，并继续处理其他映射。

## 字段编码

文件名和内容中的路径使用 UTF-8，路径相对于任务目录，分隔符为正斜线。禁止空段、点段、NUL 和保留的控制目录。引擎在访问前检查平台文件名约束，并拒绝穿过符号链接或重解析点。应用生成的 UUID 使用大写十六进制。

提交记录由两个 Base64 字段组成。body 是内层 JSON 的原始 UTF-8 字节。checksum 是对这些字节计算的 32 字节 SHA-256。读取时先验证校验值，再解析内层 JSON。解析器必须保留 64 位整数精度。单个文档最多 64 MiB。

v2 的日期是 seconds 和 nanoseconds 两个整数，Unix 时间原点，纳秒范围 0 至 999,999,999。v1 活动和版本日期沿用 Foundation 的 2001 年时间原点。迁移期间按代次选用对应解码方式。

## 提交和恢复

- 内层 JSON 包含 id、generation、edits、chunks、pruned、retiredPacks。v2 添加 version 为 2、当前 writer UUID 以及可选 takeover。
- Mac 提交可附带 run，其中 id 和 started 标记所属备份轮次。读取端可用它重建已提交的文件清单，轮次的完成状态存于本机索引。
- 每条编辑包含 method、path 和 rollbackBlocks，可含 from、before、originalAttributes、archive、next、staging、activity。操作包括 record、install、patch、attributes、remove、move、caseMove，以及 v2 的 archive。archive 只归档历史，保留当前文件记录。
- next 含 path、source、可选 target、attributes、hashes、可选 link、可选 portableID。两个 stamp 包含 kind、size、modified。v2 将 inode、birth、changed、flags、links 和 mode 等身份字段清零。本机的原生身份、观察时间及事件游标留在 SQLite。
- 复用目标中已有的目录时，next 可包含 sharedDirectory 为 true。源目录移除后，仅移除该目录的索引记录，保留硬盘上的目录。
- hashes 将每个 65,536 字节块的 32 字节 SHA-256 按文件顺序拼接后编码为 Base64。最后一块长度由文件大小决定，空文件没有块。归档 chunk 由 hash、pack UUID、字节 offset 和 length 定位。恢复时对每块重新校验。
- attributes 保存通用修改和创建时间，以及 Mac mode、extended、acl、可选 Windows 文件属性 windows 和链接字段 windowsLink、windowsLinkDirectory。link 是以 Base64 编码的链接目标。平台特有内容与该文件版本一同保存。
- Mac 上的 exFAT 可保留 macOS 名称以及已有的实际符号链接。Windows 回放并保留这些记录，将无法在 Windows 表示的项目列为待处理。若未提交的事务需要写入此类名称或实际的 Mac 链接，需在 Mac 上恢复。
- 持有文件锁后验证代次和当前提交。先落盘归档包与准备记录，再应用编辑、落盘并发布提交记录。匹配已提交代次和 ID 的准备记录可清除。下一代未提交的记录逆序回滚。块的内容与预期的旧块或新块均不符时，保留记录并停止写入。
- 历史清理先提交过期的版本 ID。块包仅在其可用块无保留版本引用，或已提交新包位置后才回收。应用退出、推出或暂停在当前事务边界处理。

## 迁移和写入权

legacyGeneration 记录旧版提交的末代次。升级先完成旧事务与日志回放，最后原子替换任务标记。旧提交和仍有引用的块包保留。没有未完成事务的 v1 exFAT 备份可在任一端升级。

initialWriter 标记原始写入者。接管提交带 takeover 为 true，writer 为新写入者，编辑和清理清单为空。普通提交的 writer 必须延续当前写入者。接管前归档本机内容的操作可以在保持原写入者的情况下提交。两端用本机卷身份与盘上任务 UUID 共同识别目标。

未绑定的源必须为空。已绑定的源以本机保存的对齐基线、当前源和已提交硬盘内容比较。确认前重查内容和提交代次，确认后保存接管检查点。覆盖或移除本机内容前先将其归档。源对齐完成后提交写入权，重新建立本机基线与监听。

## 测试样本

Swift 测试在合成的两个块文件上先提交一个更改，再留下写到一半的事务。C++ 测试恢复旧提交、读取归档、接管后修改第二个块，再留下 C++ 的未提交事务。Swift 导入该结果，校验两块及历史内容并再次接管。GitHub Actions 交换这些样本。样本中的文件、任务标识和本机索引均为测试数据。

集合样本由 Swift 生成最新副本和历史，C++ 读取后接管并生成下一版历史，在集合目录移动后中断。Swift 再恢复目录移动、校验最新内容、还原双方历史并接管到空目录。两端各自覆盖集合准备、目录移动和主标记发布三个中断点。
