# SET

[Commands](README.md) / SET

Store a string value, with optional write conditions and expiration.

## Syntax

```text
SET key value [NX | XX] [GET]
    [EX seconds | PX milliseconds | EXAT unix-seconds |
     PXAT unix-milliseconds | KEEPTTL]
```

Options may appear in another order. Each option group can occur only once.

## Examples

Store and replace a value:

```console
127.0.0.1:6379> SET example:color blue
OK
127.0.0.1:6379> SET example:color green GET
"blue"
127.0.0.1:6379> GET example:color
"green"
```

Set only when a key is absent:

```console
127.0.0.1:6379> SET example:color red NX
(nil)
127.0.0.1:6379> GET example:color
"green"
```

Give a value a 60-second lifetime:

```console
127.0.0.1:6379> SET example:session active EX 60
OK
```

## Options

| Option | Meaning |
| --- | --- |
| `NX` | Write only when the key is absent. |
| `XX` | Write only when the key is present. |
| `GET` | Return the previous value instead of `OK`. |
| `EX seconds` | Expire after this many seconds. |
| `PX milliseconds` | Expire after this many milliseconds. |
| `EXAT unix-seconds` | Expire at this Unix timestamp in seconds. |
| `PXAT unix-milliseconds` | Expire at this Unix timestamp in milliseconds. |
| `KEEPTTL` | Preserve the key's existing expiration. |

A normal applied SET clears the old expiration. An expiration option replaces
it. KEEPTTL preserves it. A rejected NX or XX write changes neither the value
nor its expiration. Expired keys count as absent for these conditions.

Expiration values must be positive decimal integers. Converting to milliseconds
and adding a relative duration must fit a signed 64-bit timestamp. Zero,
negative, malformed, missing, and overflowing values are errors. A positive
absolute timestamp may already be in the past; the stored value is then expired.

Unknown options and repeated groups are errors. For example, `NX XX`,
`EX 60 PX 1000`, and `GET GET` are rejected before writing. Conditions such as
`IFEQ`, `IFNE`, `IFDEQ`, and `IFDNE` are unsupported.

Keys and values can be empty or binary. The request must fit the
[protocol limits](../reference/protocol.md).

## Return information

GET changes the reply independently of whether the write is accepted:

| Request outcome | Without GET | With GET |
| --- | --- | --- |
| Write applies and a previous value existed | `OK` | Previous value |
| Write applies and no previous value existed | `OK` | Null |
| NX rejects an existing key | Null | Previous value |
| XX rejects a missing key | Null | Null |

`OK` is a simple string in both protocols. A previous value is a RESP2 bulk
string or RESP3 blob string. Null is `$-1\r\n` in RESP2 and `_\r\n` in RESP3.
An empty previous value is an empty string, not null.

An I/O error can occur after an applied write. An error does not always mean
the value was rolled back. Read the [persistence failure contract](../operate/persistence.md)
before adding automatic retries.

## Related commands

[GET](get.md), [DEL](del.md), [SELECT](select.md).
