const std = @import("std");
const object = @import("object.zig");
const time = @import("time.zig");

pub const ObjectExpiration = struct {
    // NOTE: This key is borrowed from the `HashTable/HashMap`. `HashTable/HashMap` owns the key
    // So we don't need to free the key by ourselves.
    // Freeing the keys from the `HashTable/HashMap` is enough
    key: []const u8,
    expires_at: time.UnixMs,
};

pub const Object = struct {
    value: object.Object,
    // Direct index into the expiration list. We need it even for keys without
    // an expiration (`null`) so removing or updating an expiration can be O(1).
    // On a 64-bit target, `?usize` occupies 16 bytes (payload plus presence tag and
    // padding), making this whole struct 32 bytes rather than 16 bytes.
    //
    // Direct expiration metadata cost on this target (excluding hash-map keys,
    // values, buckets, and unused capacity):
    //
    //   keys   exp_index on all keys   expiration record per TTL key   total if all expire
    //   100K   1.6 MB                  2.4 MB                          5.6 MB
    //   1M     16 MB                   24 MB                           56 MB
    //   10M    160 MB                  240 MB                          560 MB
    //   100M   1.6 GB                  2.4 GB                          5.6 GB
    //
    // TODO: Replace the general-purpose hash table with a purpose-built storage
    // structure if this overhead becomes too large at the intended scale.
    // https://github.com/kgxlabs/kgcache/issues/20
    exp_index: ?usize,
};
