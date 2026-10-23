include "semver";

def check($condition; $name):
  if $condition then . else error("failed SemVer check: " + $name) end;

["1.0.0-alpha", "1.0.0-alpha.1", "1.0.0-alpha.beta", "1.0.0-beta",
 "1.0.0-beta.2", "1.0.0-beta.11", "1.0.0-rc.1", "1.0.0"] as $ordered
| check(all(range(0; $ordered | length); . as $a | all(range($a + 1; $ordered | length);
    semver_compare($ordered[$a]; $ordered[.]) == -1 and
    semver_compare($ordered[.]; $ordered[$a]) == 1)); "official prerelease ordering")
| check(semver_compare("1.9.0"; "1.10.0") == -1; "numeric minor ordering")
| check(semver_compare("9.100.100"; "10.0.0") == -1; "major takes precedence")
| check(semver_compare("9007199254740992.0.0"; "9007199254740993.0.0") == -1; "large core numbers")
| check(semver_compare("1.0.0-18446744073709551616"; "1.0.0-18446744073709551617") == -1; "large candidate numbers")
| check(semver_compare("1.0.0-99999"; "1.0.0-A") == -1; "numeric before alphanumeric")
| check(semver_compare("1.0.0-Z"; "1.0.0-a") == -1; "ASCII identifier ordering")
| check(semver_compare("1.0.0+001"; "1.0.0+different") == 0; "metadata has equal precedence")
| check(semver_compare("1.0.0-rc.1+x"; "1.0.0-rc.1+y") == 0; "candidate metadata has equal precedence")
| check(("0" | numeric_increment) == "1"; "first counter")
| check(("99" | numeric_increment) == "100"; "decimal carry")
| check(("999999999999999999999999999999999999" | numeric_increment) ==
    "1000000000000000000000000000000000000"; "unbounded decimal carry")
| check(("1.2.3-rc.0+build.001" | docker_tag) == "1.2.3-rc.0_build.001"; "reversible Docker mapping")
| check(("1.2.3+" + ("a" * 122) | docker_tag | length) == 128; "128-character Docker boundary")
| check((try ("1.2.3+" + ("a" * 123) | docker_tag | false) catch contains("128")); "Docker length rejection")
| check((try ("01" | numeric_increment | false) catch contains("canonical")); "invalid increment input")
| true
