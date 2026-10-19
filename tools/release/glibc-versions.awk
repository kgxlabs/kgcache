# Extract required GLIBC versions and reject requirements above the baseline.
function reject(message) {
    print "release: " message > "/dev/stderr"
    failed = 1
    exit 1
}

function check_version(symbol, version, parts, i) {
    if (symbol !~ /^GLIBC_[0-9]+\.[0-9]+(\.[0-9]+)?$/) {
        reject("unsupported glibc symbol version: " symbol)
    }
    version = symbol
    sub(/^GLIBC_/, "", version)
    split(version, parts, ".")
    for (i = 1; i <= 3; i++) {
        if (parts[i] + 0 < allowed[i] + 0) return
        if (parts[i] + 0 > allowed[i] + 0) {
            reject(symbol " exceeds glibc baseline " baseline)
        }
    }
}

BEGIN {
    split(baseline, allowed, ".")
}

{
    for (field = 1; field < NF; field++) {
        if ($field == "Name:" && $(field + 1) ~ /^GLIBC_/) {
            symbol = $(field + 1)
            check_version(symbol)
            if (!(symbol in requirements)) requirement_count++
            requirements[symbol] = 1
        }
    }
}

END {
    if (failed) exit 1
    if (requirement_count == 0) reject("missing glibc symbol version requirements")
    for (symbol in requirements) print symbol
}
