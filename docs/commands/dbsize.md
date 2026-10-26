# DBSIZE

[Commands](README.md) / DBSIZE

Count stored entries in the selected database.

## Syntax

```text
DBSIZE
```

## Examples

Run this to inspect the current count:

```sh
redis-cli DBSIZE
redis-cli -n 1 DBSIZE
```

The first command counts database 0. The second counts database 1. The output
depends on the data already stored there.

## Behavior

The count applies to the connection's selected database, not every database.
An expired entry may remain in the count until GET or active expiration removes
it. DBSIZE does not scan and expire the entire database before counting.
Arguments are not accepted.

## Return information

RESP2 and RESP3 both return an integer containing the stored entry count.

## Related commands

[SELECT](select.md), [GET](get.md), [DEL](del.md).
