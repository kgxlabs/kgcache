# Persistence

kgcache can save data in two ways:

| Method | What it saves | Guide |
| --- | --- | --- |
| Snapshot | A full copy of the data at one point in time | [Snapshots](SNAPSHOTS.md) |
| AOF | Each write command, in order | [Append-only file](AOF.md) |

Snapshots are compact and easy to copy. They can miss writes made after the
last snapshot.

AOF keeps newer writes and can limit data loss after a crash. Its files grow
until they are rewritten.

Both methods can be enabled:

- `SAVE`, `BGSAVE`, and automatic `save` rules write `.kgc` snapshots.
- `appendonly yes` records writes in AOF files.
- When AOF is on, startup loads AOF instead of the `.kgc` snapshot.

Start with [Snapshots](SNAPSHOTS.md) for `SAVE` and `BGSAVE`, or
[Append-only file](AOF.md) for AOF setup and recovery.
