# Backup Genius 磁盘协议 v2

共享格式用于 exFAT。Windows NTFS 使用相同的 v2 日志格式。Mac APFS 使用 v1 和同卷克隆。

## 位置和编码

| 位置（相对备份目录） | 内容 |
| --- | --- |
| .backup-genius/job.json | 任务标记，含 version、job、format、legacyGeneration 和可选 initialWriter |
| .backup-genius/lock | 进程租约文件，Mac 用 flock，Windows 用 LockFileEx |
| .backup-genius/journal/00000000000000000001.json | 从 1 开始的 20 位十进制提交代次 |
| .backup-genius/journal/pending.json | 同一格式的准备记录 |
| .backup-genius/packs/\<UUID\> | 归档块的原始字节 |
| .backup-genius/stage/\<UUID\> | 待发布的文件或临时移动位置 |

文件名和内容中的路径使用 UTF-8，路径相对于任务目录，分隔符为正斜线。禁止空段、点段、NUL 和保留的控制目录。引擎在访问前检查平台文件名约束，并拒绝穿过符号链接或重解析点。应用生成的 UUID 使用大写十六进制。

提交记录由两个 Base64 字段组成。body 是内层 JSON 的原始 UTF-8 字节。checksum 是对这些字节计算的 32 字节 SHA-256。读取时先验证校验值，再解析内层 JSON。解析器必须保留 64 位整数精度。单个文档最多 64 MiB。

v2 的日期是 seconds 和 nanoseconds 两个整数，Unix 时间原点，纳秒范围 0 至 999,999,999。v1 活动和版本日期沿用 Foundation 的 2001 年时间原点。迁移期间按代次选用对应解码方式。

## 提交和恢复

- 内层 JSON 包含 id、generation、edits、chunks、pruned、retiredPacks。v2 添加 version 为 2、当前 writer UUID 以及可选 takeover。
- 每条编辑包含 method、path 和 rollbackBlocks，可含 from、before、originalAttributes、archive、next、staging、activity。操作包括 record、install、patch、attributes、remove、move、caseMove，以及 v2 的 archive。archive 只归档历史，保留当前文件记录。
- next 含 path、source、可选 target、attributes、hashes、可选 link、可选 portableID。两个 stamp 包含 kind、size、modified。v2 将 inode、birth、changed、flags、links 和 mode 等身份字段清零。本机的原生身份、观察时间及事件游标留在 SQLite。
- hashes 将每个 65,536 字节块的 32 字节 SHA-256 按文件顺序拼接后编码为 Base64。最后一块长度由文件大小决定，空文件没有块。归档 chunk 由 hash、pack UUID、字节 offset 和 length 定位。恢复时对每块重新校验。
- attributes 保存通用修改和创建时间，以及 Mac mode、extended、acl、可选 Windows 文件属性 windows 和链接字段 windowsLink、windowsLinkDirectory。link 是以 Base64 编码的链接目标。平台特有内容与该文件版本一同保存。
- 持有文件锁后验证代次和当前提交。先落盘归档包与准备记录，再应用编辑、落盘并发布提交记录。匹配已提交代次和 ID 的准备记录可清除。下一代未提交的记录逆序回滚。块的内容与预期的旧块或新块均不符时，保留记录并停止写入。
- 历史清理先提交过期的版本 ID。块包仅在其可用块无保留版本引用，或已提交新包位置后才回收。应用退出、推出或暂停在当前事务边界处理。

## 迁移和写入权

legacyGeneration 记录旧版提交的末代次。升级先完成旧事务与日志回放，最后原子替换任务标记。旧提交和仍有引用的块包保留。没有未完成事务的 v1 exFAT 备份可在任一端升级。

initialWriter 标记原始写入者。接管提交带 takeover 为 true，writer 为新写入者，编辑和清理清单为空。普通提交的 writer 必须延续当前写入者。接管前归档本机内容的操作可以在保持原写入者的情况下提交。两端用本机卷身份与盘上任务 UUID 共同识别目标。

未绑定的源必须为空。已绑定的源以本机保存的对齐基线、当前源和已提交硬盘内容比较。确认前重查内容和提交代次，确认后保存接管检查点。覆盖或移除本机内容前先将其归档。源对齐完成后提交写入权，重新建立本机基线与监听。

## 测试样本

Swift 测试在合成的两个块文件上先提交一个更改，再留下写到一半的事务。C++ 测试恢复旧提交、读取归档、接管后修改第二个块，再留下 C++ 的未提交事务。Swift 导入该结果，校验两块及历史内容并再次接管。GitHub Actions 交换这些样本。样本中的文件、任务标识和本机索引均为测试数据。
