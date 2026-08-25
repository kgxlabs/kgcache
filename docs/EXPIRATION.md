# Expiration bookkeeping

How TTLs are tracked alongside key/value entries, what that costs in memory, and where the design is headed as the keyspace grows.

## Layout

The default backend is intentionally straightforward today: a `StringHashMap` stores values, while an `ArrayList` holds expiration records. Each expiring entry keeps an index into that list, allowing expiration metadata to be updated or removed in O(1) time.

```text
StringHashMap(key → Entry)                Expirables: ArrayList(ObjectExpiration)
┌─────┬──────────────────────┐            ┌───────────────┬───────────────┬───┐
│ key │ value | exp_index    │            │ 0             │ 1             │...│
├─────┼──────────────────────┤            ├───────────────┼───────────────┼───┤
│"a"  │ ...   | null          │            │ key="b"       │ key="c"       │   │
│"b"  │ ...   | 0     ────────┼───────────▶│ expires_at=…  │ expires_at=…  │   │
│"c"  │ ...   | 1     ────────┼───────────▶│               │               │   │
└─────┴──────────────────────┘            └───────────────┴───────────────┴───┘
```

To locate expiration metadata, the backend first finds the key's entry in the hash map, reads its `exp_index`, and then indexes directly into the expiration array — no scan required either way.

Removing an expiration uses swap-remove: the final record fills the freed slot, and the moved key's `exp_index` is updated before the list is popped, so no gap is ever left mid-array.

```text
Removing index 0 (of 3):

before:  [ b@0 , c@1 , d@2 ]
                  swap-remove(0)
after:   [ d@0 , c@1 ]          -- d moved into slot 0, d's exp_index
                                    updated to 0, list popped from the end
```

## What it costs

On the current 64-bit target, every stored entry carries an optional `usize` named `exp_index`. It is `16 bytes`, even for persistent keys that have no expiration, so the map's stored object grows from `16 bytes` for the value to `32 bytes` with the index included. This is a deliberate space-for-time trade-off: expiration changes do not need to scan the full expiration list.

Each TTL key also has a `24-byte` expiration record in the `ArrayList` (a borrowed key slice plus an absolute millisecond timestamp).

| Metadata | Cost on a 64-bit target | Paid by |
| --- | ---: | --- |
| `exp_index: ?usize` | 16 bytes | Every key, including persistent keys |
| Expiration record | 24 bytes | Keys with a TTL |

At larger key counts, that direct per-entry cost looks like this when every key has a TTL:

| Keys | `exp_index` on all keys | Expiration records | Direct total if all expire |
| ---: | ---: | ---: | ---: |
| 100K | 1.6 MB | 2.4 MB | 5.6 MB |
| 1M | 16 MB | 24 MB | 56 MB |
| 10M | 160 MB | 240 MB | 560 MB |
| 100M | 1.6 GB | 2.4 GB | 5.6 GB |

The final column includes the base 16-byte string-value payload as well as the index and expiration record. It excludes hash-table buckets, key slices, allocator overhead, and unused `ArrayList` capacity, so real process memory will be higher.

## Where this is headed

As the cache grows, the plan is to replace this general-purpose expiration layout with a purpose-built hash-table design that supports efficient random expiration sampling, following the broad strategy used by Redis. That would reduce bookkeeping overhead and make active expiration a better fit for larger keyspaces.
