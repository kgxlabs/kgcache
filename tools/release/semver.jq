# SemVer 2.0.0. Anchors cover the whole string, including trailing newlines.
# Keep identifiers as strings so large numeric fields do not lose precision.
def semver:
  type == "string" and test(
    "\\A(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)" +
    "(-((0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*)(\\.(0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*))*))?" +
    "(\\+[0-9A-Za-z-]+(\\.[0-9A-Za-z-]+)*)?\\z");

def semver_parts:
  if semver then
    split("+") as $parts
    | ($parts[0] | index("-")) as $dash
    | (if $dash == null then $parts[0] else $parts[0][:$dash] end | split(".")) as $core
    | {major: $core[0], minor: $core[1], patch: $core[2],
       prerelease: (if $dash == null then null else $parts[0][$dash + 1:] | split(".") end),
       metadata: ($parts[1] // null)}
  else error("version must be SemVer 2.0.0") end;

def numeric_compare($a; $b):
  if $a == $b then 0
  elif [($a | length), $a] < [($b | length), $b] then -1 else 1 end;

def identifier_compare($a; $b):
  if ($a | test("^[0-9]+$")) and ($b | test("^[0-9]+$")) then numeric_compare($a; $b)
  elif $a == $b then 0
  elif ($a | test("^[0-9]+$")) then -1
  elif ($b | test("^[0-9]+$")) then 1
  elif $a < $b then -1 else 1 end;

def semver_compare($left; $right):
  ($left | semver_parts) as $a | ($right | semver_parts) as $b
  | [numeric_compare($a.major; $b.major), numeric_compare($a.minor; $b.minor),
     numeric_compare($a.patch; $b.patch)] as $core
  | if any($core[]; . != 0) then first($core[] | select(. != 0))
    elif $a.prerelease == $b.prerelease then 0
    elif $a.prerelease == null then 1
    elif $b.prerelease == null then -1
    else
      [range(0; ([($a.prerelease | length), ($b.prerelease | length)] | min))
       | identifier_compare($a.prerelease[.]; $b.prerelease[.])] as $pre
      | if any($pre[]; . != 0) then first($pre[] | select(. != 0))
        elif ($a.prerelease | length) < ($b.prerelease | length) then -1 else 1 end
    end;

# Only individual decimal digits are converted to numbers.
def numeric_increment:
  if type != "string" or (test("\\A(0|[1-9][0-9]*)\\z") | not) then
    error("increment requires a canonical numeric string")
  else
    reduce (explode | reverse[]) as $digit
      ({carry: 1, digits: []};
       ($digit - 48 + .carry) as $sum
       | .digits += [48 + ($sum % 10)] | .carry = (if $sum >= 10 then 1 else 0 end))
    | (if .carry == 1 then .digits + [49] else .digits end) | reverse | implode
  end;

def next_candidate($target; $prefix; $releases):
  ("0.0.0-" + $prefix + ".1" | semver_parts | .prerelease[:-1]) as $prefix_parts
  | ($releases | map(.version | semver_parts | select(.prerelease != null)
       | select((.major + "." + .minor + "." + .patch) == $target)
       | select(.prerelease[:-1] == $prefix_parts)
       | .prerelease[-1] | select(test("\\A(0|[1-9][0-9]*)\\z")))) as $counters
  | (reduce $counters[] as $counter ("0";
       if numeric_compare($counter; .) > 0 then $counter else . end) | numeric_increment) as $next
  | $target + "-" + $prefix + "." + $next;

def docker_tag:
  if semver then sub("\\+"; "_")
  else error("version must be SemVer 2.0.0") end
  | if length <= 128 and test("\\A[A-Za-z0-9_][A-Za-z0-9_.-]*\\z") then .
    else error("mapped Docker tag exceeds 128 characters or is invalid") end;
