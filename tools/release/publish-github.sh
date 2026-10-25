#!/usr/bin/env bash
# GitHub transport and release assembly for publish.sh. No source builds run here.
# The entry point owns and validates these shared context values.
# shellcheck disable=SC2154

publish_api=https://api.github.com
publish_http_code=

publish_api_call() {
    local method=$1 path=$2 output=$3 data=${4:-} content=${5:-application/json} host=$publish_api
    local options=()

    [[ "$path" == "/repos/$publish_repository/"* && "$path" != *$'\n'* ]] || release_fail 'unexpected release API path'
    if [[ "$method" == UPLOAD ]]; then
        method=POST
        if [[ "$publish_fixture" == false ]]; then host=https://uploads.github.com; fi
    fi
    [[ -z "$data" ]] || options=(--data-binary "@$data" --header "Content-Type: $content")
    if [[ "$method" != GET ]]; then publish_authorize; fi
    publish_http_code=000
    # Writes are not retried. Callers reconcile their exact intended identity.
    if publish_http_code=$(timeout --signal=TERM --kill-after=5s 90s curl \
        --silent --show-error --max-time 60 --connect-timeout 10 --max-filesize 2097152 \
        --request "$method" --header 'Accept: application/vnd.github+json' \
        --header 'X-GitHub-Api-Version: 2022-11-28' \
        --header "Authorization: Bearer ${GH_TOKEN:-fixture}" \
        ${options[@]+"${options[@]}"} --output "$output" --write-out '%{http_code}' "$host$path"); then
        :
    else publish_http_code=000; fi
}

publish_find_release() {
    local tag=$1 page count

    : > "$publish_workspace/releases.jsonl"
    for ((page = 1; page <= 20; page++)); do
        publish_api_call GET "/repos/$publish_repository/releases?per_page=100&page=$page" "$publish_workspace/page.json"
        [[ "$publish_http_code" == 200 ]] || release_fail 'cannot list releases for reconciliation'
        jq -ce 'if type == "array" then . else error("expected releases") end' \
            "$publish_workspace/page.json" >> "$publish_workspace/releases.jsonl"
        count=$(jq 'length' "$publish_workspace/page.json")
        [[ "$count" == 100 ]] || break
    done
    [[ "$count" != 100 ]] || release_fail 'release listing exceeds reconciliation limit'
    jq -s --arg tag "$tag" 'add | map(select(.tag_name == $tag)) |
        if length > 1 then error("duplicate releases for tag") else .[0] // null end' \
        "$publish_workspace/releases.jsonl" > "$publish_workspace/release.json"
}

publish_assets() {
    local path policy checksum bytes file

    mkdir -p "$publish_workspace/assets"
    if jq -e '.proposal.mode == "release"' "$publish_workspace/request.json" > /dev/null; then
        jq -j '.proposal.release_notes.body' "$publish_workspace/request.json" > "$publish_workspace/notes.md"
        checksum=$(release_sha256 "$publish_workspace/notes.md")
        jq -e --arg sha "$checksum" '.proposal.release_notes.sha256 == $sha' \
            "$publish_workspace/request.json" > /dev/null || release_fail 'frozen PR notes differ'
    else
        policy=$(jq -r '.proposal.policy_sha' "$publish_workspace/request.json")
        path=$(jq -r '.proposal.notes_ref' "$publish_workspace/request.json")
        [[ "$path" =~ ^[A-Za-z0-9_.-]+(/[A-Za-z0-9_.-]+)*$ && "$path" != /* &&
            "$path" != *..* && "$path" != -* ]] || release_fail 'notes_ref must be a reviewed repository file path'
        publish_api_call GET "/repos/$publish_repository/contents/$path?ref=$policy" "$publish_workspace/notes.json"
        [[ "$publish_http_code" == 200 ]] || release_fail 'reviewed release notes are unavailable'
        jq -je 'if .type == "file" and .encoding == "base64" then .content | @base64d
        else error("expected reviewed note file") end' "$publish_workspace/notes.json" > "$publish_workspace/notes.md"
        checksum=$(git hash-object "$publish_workspace/notes.md")
        jq -e --arg sha "$checksum" '.sha == $sha' "$publish_workspace/notes.json" > /dev/null || release_fail 'reviewed note bytes differ'
    fi
    [[ -s "$publish_workspace/notes.md" ]] || release_fail 'reviewed release notes are empty'
    cp "$publish_workspace/bundle/build-info.json" "$publish_workspace/assets/build-info.json"
    jq -n --slurpfile request "$publish_workspace/request.json" \
        --slurpfile candidate "$publish_workspace/bundle/candidate.json" \
        '{schema_version: 1, repository: $candidate[0].repository,
          source_sha: $candidate[0].source_sha, version: $candidate[0].version,
          platform: $candidate[0].platform, request_key: $request[0].request_key,
          policy_sha: $request[0].proposal.original_policy_sha,
          tag_object_sha: $request[0].tag_object_sha, candidate_sha256: $request[0].candidate_sha256,
          image: {repository: $request[0].registry.intent.repository,
            digest: $request[0].registry.fixed.digest, config_digest: $candidate[0].image.id,
            source_version_key: $candidate[0].image.source_version_key,
            tags: $request[0].registry.fixed.tags}, build: $candidate[0].build}' \
        > "$publish_workspace/assets/release-info.json"
    jq -n --slurpfile candidate "$publish_workspace/bundle/candidate.json" \
        --slurpfile request "$publish_workspace/request.json" \
        '{schema_version: 1, source_sha: $candidate[0].source_sha, version: $candidate[0].version,
          qualification: $candidate[0].qualification, checks: $candidate[0].checks,
          client_coverage: $candidate[0].client_coverage, registry: $request[0].registry.verified}' \
        > "$publish_workspace/assets/qualification.json"
    : > "$publish_workspace/assets/SHA256SUMS"
    : > "$publish_workspace/assets.jsonl"
    for file in build-info.json release-info.json qualification.json SHA256SUMS; do
        checksum=$(release_sha256 "$publish_workspace/assets/$file")
        bytes=$(candidate_file_size "$publish_workspace/assets/$file")
        jq -cn --arg name "$file" --arg sha "$checksum" --argjson bytes "$bytes" \
            '{name: $name, sha256: $sha, bytes: $bytes}' >> "$publish_workspace/assets.jsonl"
        if [[ "$file" != SHA256SUMS ]]; then
            printf '%s  %s\n' "$checksum" "$file" >> "$publish_workspace/assets/SHA256SUMS"
        fi
    done
    jq -s . "$publish_workspace/assets.jsonl" > "$publish_workspace/asset-inventory.json"
    jq -n --slurpfile request "$publish_workspace/request.json" --rawfile notes "$publish_workspace/notes.md" \
        --slurpfile assets "$publish_workspace/asset-inventory.json" \
        '$request[0] as $r | {tag_name: $r.proposal.intended_tag, name: $r.proposal.intended_tag,
          target_commitish: $r.source_sha, prerelease: ($r.proposal.channel == "prerelease"),
          body: ($notes + "\n\nImage: `" + $r.registry.intent.repository + "@" + $r.registry.fixed.digest +
            "`\n\nPlatform: `linux/amd64`\nSource: `" + $r.source_sha + "`\n"), assets: $assets[0]}' \
        > "$publish_workspace/github-intent.json"
}

publish_download_asset() {
    local id=$1 output=$2
    local options=()

    [[ "$id" =~ ^[1-9][0-9]*$ ]] || release_fail 'invalid asset ID'
    if [[ "$publish_fixture" == false ]]; then
        # curl drops Authorization on cross-host redirects. Never use
        # --location-trusted. Redirect destinations must use HTTPS.
        options=(--location --max-redirs 3 --proto '=https' --proto-redir '=https')
    fi
    timeout --signal=TERM --kill-after=5s 90s curl --fail --silent --show-error \
        --max-time 60 --connect-timeout 10 --max-filesize 1048576 \
        --header 'Accept: application/octet-stream' --header "Authorization: Bearer ${GH_TOKEN:-fixture}" \
        ${options[@]+"${options[@]}"} --output "$output" \
        "$publish_api/repos/$publish_repository/releases/assets/$id"
}

publish_release() {
    local tag id name asset_id expected actual found draft digest

    digest=$(jq -r '.registry.fixed.digest' "$publish_workspace/request.json")
    jq -r '.registry.fixed.tags[]' "$publish_workspace/request.json" > "$publish_workspace/fixed-tags"
    while IFS= read -r tag; do
        publish_manifest "$publish_registry:$tag" "$publish_workspace/fixed.json"
        jq -e --arg digest "$digest" '.digest == $digest' "$publish_workspace/fixed.json" > /dev/null ||
            release_fail 'fixed registry reference changed before GitHub publication'
    done < "$publish_workspace/fixed-tags"
    publish_assets
    publish_checkpoint github_intent "$publish_workspace/github-intent.json"
    tag=$(jq -r '.tag_name' "$publish_workspace/github-intent.json")
    publish_find_release "$tag"
    if jq -e '. == null' "$publish_workspace/release.json" > /dev/null; then
        jq 'del(.assets) | . + {draft: true, make_latest: "false"}' \
            "$publish_workspace/github-intent.json" > "$publish_workspace/create.json"
        publish_api_call POST "/repos/$publish_repository/releases" "$publish_workspace/response.json" \
            "$publish_workspace/create.json"
        publish_find_release "$tag"
    fi
    jq -e --slurpfile intent "$publish_workspace/github-intent.json" \
        '.id > 0 and .tag_name == $intent[0].tag_name and .name == $intent[0].name and
         .target_commitish == $intent[0].target_commitish and .body == $intent[0].body and
         .prerelease == $intent[0].prerelease' "$publish_workspace/release.json" > /dev/null ||
        release_fail 'release conflicts with its original tag, source, or notes'
    id=$(jq -r '.id' "$publish_workspace/release.json")
    jq -n --argjson id "$id" '{id: $id}' > "$publish_workspace/draft.json"
    publish_checkpoint draft "$publish_workspace/draft.json"
    jq -r '.[].name' "$publish_workspace/asset-inventory.json" > "$publish_workspace/asset-names"
    while IFS= read -r name; do
        publish_api_call GET "/repos/$publish_repository/releases/$id/assets?per_page=100" "$publish_workspace/remote-assets.json"
        [[ "$publish_http_code" == 200 ]] || release_fail 'cannot inspect release assets'
        found=$(jq --arg name "$name" '[.[] | select(.name == $name)] | length' "$publish_workspace/remote-assets.json")
        [[ "$found" -le 1 ]] || release_fail 'duplicate release asset name'
        if [[ "$found" == 0 ]]; then
            draft=$(jq -r '.draft' "$publish_workspace/release.json")
            [[ "$draft" == true ]] || release_fail 'published release is missing an asset; do not modify it'
            publish_api_call UPLOAD "/repos/$publish_repository/releases/$id/assets?name=$name" \
                "$publish_workspace/response.json" "$publish_workspace/assets/$name" application/octet-stream
            publish_api_call GET "/repos/$publish_repository/releases/$id/assets?per_page=100" "$publish_workspace/remote-assets.json"
            [[ "$publish_http_code" == 200 ]] || release_fail 'cannot reconcile uploaded asset'
        fi
        asset_id=$(jq -er --arg name "$name" '[.[] | select(.name == $name)] |
            if length == 1 and .[0].state == "uploaded" then .[0].id else error("missing complete asset") end' \
            "$publish_workspace/remote-assets.json")
        publish_download_asset "$asset_id" "$publish_workspace/downloaded"
        expected=$(release_sha256 "$publish_workspace/assets/$name")
        actual=$(release_sha256 "$publish_workspace/downloaded")
        [[ "$expected" == "$actual" ]] || release_fail "release asset bytes conflict: $name"
    done < "$publish_workspace/asset-names"
    jq -e --slurpfile expected "$publish_workspace/asset-inventory.json" \
        '([.[].name] | sort) == ([$expected[0][].name] | sort)' \
        "$publish_workspace/remote-assets.json" > /dev/null || release_fail 'unexpected release assets'
    if jq -e '.draft == true' "$publish_workspace/release.json" > /dev/null; then
        jq '{draft: false, prerelease, make_latest: "false"}' "$publish_workspace/github-intent.json" \
            > "$publish_workspace/publish.json"
        publish_api_call PATCH "/repos/$publish_repository/releases/$id" "$publish_workspace/response.json" \
            "$publish_workspace/publish.json"
    fi
    publish_find_release "$tag"
    jq -e --argjson id "$id" --slurpfile intent "$publish_workspace/github-intent.json" \
        '.id == $id and .draft == false and .prerelease == $intent[0].prerelease and
         .tag_name == $intent[0].tag_name and .body == $intent[0].body' \
        "$publish_workspace/release.json" > /dev/null || release_fail 'published release read-back failed'
    jq -n --argjson id "$id" '{id: $id, verified: true}' > "$publish_workspace/published.json"
    publish_checkpoint published "$publish_workspace/published.json"
}
