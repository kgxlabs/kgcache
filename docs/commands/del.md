# DEL

[Commands](README.md) / DEL

Remove one or more keys from the selected database.

## Syntax

```text
DEL key [key ...]
```

## Examples

```console
127.0.0.1:6379> SET example:first one
OK
127.0.0.1:6379> SET example:second two
OK
127.0.0.1:6379> DEL example:first example:second
(integer) 2
127.0.0.1:6379> DEL example:first
(integer) 0
```

## Behavior

DEL processes keys in the selected database. Missing and expired keys do not
increase the count. At least one key is required.

Each removal is applied separately. If a later removal fails, earlier successful
removals remain applied. Do not use a multi-key DEL as a transaction.

## Return information

RESP2 and RESP3 both return an integer: the number of keys that existed and
were removed.

## Related commands

[GET](get.md), [SET](set.md), [DBSIZE](dbsize.md), [SELECT](select.md).
