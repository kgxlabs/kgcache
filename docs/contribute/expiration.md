# Understand expiration storage

[Docs](../README.md) / [Contribute](README.md) / Expiration

Expiration has a read path and a sampled background path. Both remove data
through the storage transaction boundary. Use this guide when changing TTL
bookkeeping or cron policy. The application-facing behavior is in
[strings and expiration](../develop/strings.md).

## Trace an expiration round

[cron.zig](../../src/cron.zig) calls
[expiration.runRound](../../src/expiration.zig) after each configured tick.
One `active-expire-budget-ms` limit covers the whole round across databases.

For each database, the round samples a batch of TTL records. When the expired
percentage reaches `active-expire-threshold-percent`, it tries another batch
while budget remains. `active-expire-batch-size` sets the sample count. The
starting database rotates between rounds so a busy database does not always
consume the first part of the budget.

Each count check and sampled removal takes a storage transaction. It releases
that transaction on success and failure. Active expiration is enabled today;
the older warning about an unreleased storage lock no longer describes it.

GET also removes an expired entry when reading it. Sampling does not remove
every entry at its exact deadline. DBSIZE can still include expired entries
until lazy or active cleanup reaches them.

## Maintain the indexes

The default backend uses a hash map for values and an array for TTL records:

```text
Hash map entry                    Expiration array
key -> value, exp_index ----------> key slice, expires_at
```

An entry without expiration has a null `exp_index`. An expiring entry holds
its index into the array. This gives direct access to the TTL record after a
key lookup.

Removal uses swap-remove. Move the final TTL record into the removed slot,
update that moved key's index, then shorten the array. Keep these changes in
the same transaction. Otherwise a later removal could address another key's
record or a freed slot.

```text
before: [b@0, c@1, d@2]
remove: b@0
after:  [d@0, c@1]       d's map entry now points to index 0
```

TTL records borrow their key slices from stored entries. Preserve that lifetime
when replacing keys or changing the backend. Applied expiration removals pass
through `NotifierStorage`, so they also produce journal DEL records and advance
the dirty count.

## Account for metadata

On the current 64-bit target:

| Part | Size | Applies to |
| --- | ---: | --- |
| Base string-value payload | 16 bytes | Every key |
| `exp_index: ?usize` | 16 bytes | Every key, even without a TTL |
| Expiration array record | 24 bytes | Each key with a TTL |

If every key expires, these direct parts total 56 bytes per key: 5.6 MB for
100,000 keys, 56 MB for one million, or 560 MB for ten million. They exclude
value bytes, keys, hash buckets, allocator overhead, and spare array capacity.
They are not estimates of total process memory.

This layout trades metadata space for direct TTL updates and random sampling.
Changing it needs to preserve index consistency, borrowing rules, sampling,
and journaled deletion semantics.

## Verify a change

Run `zig build test`. The regression cases in
[expiration.zig](../../src/expiration.zig) cover multiple databases and the
largest configured batch. [Storage tests](../../src/storage) cover session
release, swap-remove bookkeeping, journal preparation failure, and applied
expiration records. Add a test at the boundary whose invariant changes.
