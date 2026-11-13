# Immutable restore points, extension 1

This is an additive, optional extension to the existing v1/v2 repository. The job marker and transaction recovery protocol are unchanged. The extension lives under the **resolved control tree** `points/`, never alongside user files in a collection root. Old clients do not traverse or prune this namespace. Both updated clients read and write the same representation on exFAT.

## Layout and encoding

- `records/00000000000000000001.json`: completed point receipt; sequence starts at 1 without gaps.
- `segments/<UUID>`: immutable metadata deltas and new chunk locations, at most 128 file entries per segment.
- `packs/<UUID>`: concatenated immutable payload blocks, fixed 65,536 bytes except the final file block.
- `clones/<UUID>`: APFS-only immutable clones; these points require Mac/APFS.

Documents are envelopes `{ "body": "Base64(original JSON bytes)", "checksum": "Base64(SHA256(original JSON bytes))" }`. Verify original bytes before decoding. Integers must retain 64-bit precision; all times are `{seconds, nanoseconds}` relative to Unix epoch. UTF-8 relative paths use the existing v2 validation rules. UUIDs use uppercase canonical strings. Optional keys may be absent.

Receipt fields: `version: 1`, `id: UUID`, `previous: UUID?`, `sequence: Int64`, `created: FileTime`, `files: Int64`, `segments: [UUID]`, `generation: Int64?`. `previous` is absent on the first point. `generation` identifies the durable main-journal generation captured. A successful backup with the same generation can append an empty-segment receipt referencing the previous state; this performs no user-file reads and adds no payload blocks. Older extension receipts without `generation` remain readable.

Segment fields: `entries: [PointEntry]`, `chunks: [ChunkLocation]`. `PointEntry` contains `path`, optional `record` (the existing v2 `FileRecord`), and optional APFS `clone` UUID. Absence of `record` is a tombstone. Deltas set or remove **one exact path**. Directory moves include descendant entries. Current sources and native source IDs are never required for restoration. `ChunkLocation` uses the existing hash/pack/offset/length schema. SHA-256 hash identity permits block reuse across files and points.

## Publication, restoration and interruption

Hold the repository's exclusive OS lease. Recover main-journal transactions first. Only a successful complete sync may publish a receipt. Prepare immutable chunks/clones, flush data and containing directories, then flush the segments. Atomically publish and flush the final receipt as the completion point. A crash before publication leaves unreachable preparation data; it never exposes a partial point. A crash after publication leaves a valid point even if the local activity index has not recorded completion. Retrying is safe.

Reconstruct the selected tree by replaying segments through its receipt. Restore into a newly created staging directory, verify every payload block (or clone) against its recorded hashes, apply the point's saved metadata, and publish a new visible restore directory only after completion. Never depend on mutable latest files. Invalid names, unsupported links, a missing pack, or checksum failures abort restoration and remove the incomplete staging tree. Windows may require Developer Mode / link permission; links not representable on that platform must be restored on Mac.

No receipt is synthesized for an old backup run: earlier clients did not preserve enough immutable data to guarantee a full point. Existing single-file history remains usable independently.

## Retention and resources

Keep data referenced by points within 30 days and by the latest complete point, even if that point is older. At most once per day during successful backup maintenance, replay retained points and delete only wholly unreferenced pack/clone files. Cleanup is repeatable after interruption. Shared packs may retain expired unreferenced blocks until all live references to that pack disappear. Metadata receipts and delta segments remain as the replay chain; this revision does not compact that chain. This is a storage overhead limitation, not a promise to reclaim every expired byte exactly on day 30.

Payload I/O uses bounded blocks. Unchanged points read receipt headers only; content indices are loaded lazily for changed-point capture, restoration or cleanup. First capture reads the existing managed index and creates an independent baseline. Subsequent changed capture compares metadata recipes; user-file bodies are only read for previously unstored hashes. Source detection continues to use its event queue. Full metadata recipe replay can add CPU and memory overhead on very large histories; benchmark it separately from source scanning. Health queries and speed tests do not affect this protocol.
