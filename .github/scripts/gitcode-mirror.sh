#!/usr/bin/env bash
# Mirror a GitHub release (metadata + assets) to GitCode (gitcode.com).
#
# Idempotent: re-running only uploads assets that are missing on GitCode or
# whose size differs from the GitHub copy.
#
# GitCode API reference: https://docs.gitcode.com/en/docs/apis/
#   - Releases are addressed by tag name, not by numeric id.
#   - Request bodies are JSON; the token goes in the access_token query param.
#   - Assets are not POSTed to the API. Instead, GET .../upload_url returns a
#     pre-signed object-storage URL plus headers; the file is PUT there with
#     those headers unchanged, and storage calls GitCode back to attach it.
#
# Required env: GH_TOKEN, GITCODE_TOKEN, GITCODE_OWNER, GITCODE_REPO, TAG,
#               GITHUB_REPOSITORY
# Optional env: WAIT_FOR_ASSETS=true
#               ASSET_FILTER=<regex>  only sync assets whose name matches
#               UPLOAD_MAX_TIME=<s>   cap each upload (for throughput tests)
set -euo pipefail

API="https://api.gitcode.com/api/v5/repos/${GITCODE_OWNER}/${GITCODE_REPO}"
TAG_PATH=$(jq -rn --arg t "$TAG" '$t | @uri')   # tag, escaped for URL paths

gh_release() {
  gh release view "$TAG" -R "$GITHUB_REPOSITORY" \
    --json name,body,isPrerelease,assets
}

asset_fingerprint() {
  gh_release | jq -c '[.assets[] | {name, size}] | sort_by(.name)'
}

gitcode_release() {
  curl -sS -G "$API/releases/tags/$TAG_PATH" \
    --data-urlencode "access_token=$GITCODE_TOKEN"
}

# --- Wait for the asset list to stop changing -----------------------------
if [ "${WAIT_FOR_ASSETS:-false}" = "true" ]; then
  stable_needed=5   # consecutive identical polls (1 min apart)
  max_polls=60
  last="" stable=0
  for ((i = 0; i < max_polls; i++)); do
    cur=$(asset_fingerprint)
    if [ "$cur" = "$last" ] && [ "$cur" != "[]" ]; then
      stable=$((stable + 1))
    else
      stable=0
    fi
    last="$cur"
    echo "Assets: $(jq length <<<"$cur") (stable for $stable/$stable_needed polls)"
    [ "$stable" -ge "$stable_needed" ] && break
    sleep 60
  done
fi

# --- Wait for GitCode's repository mirror to pick up the tag --------------
# The GitCode repo pulls git history from GitHub on its own; the release must
# be attached to a tag that already exists there. GitCode has no single-tag
# endpoint and its tag list cannot be sorted, so page through all of it.
tag_on_gitcode() {
  local page out
  for ((page = 1; page <= 50; page++)); do
    out=$(curl -sS -G "$API/tags" --data-urlencode "access_token=$GITCODE_TOKEN" \
      --data-urlencode "per_page=100" --data-urlencode "page=$page") || return 1
    jq -e --arg t "$TAG" 'any(.[]; .name == $t)' <<<"$out" >/dev/null 2>&1 && return 0
    # Stop at the last (short or empty) page, or on a non-array error body.
    [ "$(jq 'if type == "array" then length else 0 end' <<<"$out" 2>/dev/null || echo 0)" -lt 100 ] && return 1
  done
  return 1
}

for ((i = 0; ; i++)); do
  tag_on_gitcode && { echo "Tag $TAG present on GitCode"; break; }
  if [ "$i" -ge 30 ]; then
    echo "::error::Tag $TAG did not appear on GitCode after 30 minutes. Sync the GitCode repository mirror, then re-run this workflow."
    exit 1
  fi
  echo "Waiting for tag $TAG to be mirrored to GitCode..."
  sleep 60
done

release=$(gh_release)
name=$(jq -r '.name // empty' <<<"$release")
body=$(jq -r '.body // empty' <<<"$release")
prerelease=$(jq -r '.isPrerelease' <<<"$release")
name="${name:-$TAG}"
body="${body:-Release $TAG}"   # name and body are required by GitCode

# GitCode has release_status (pre | latest) instead of a prerelease flag.
# Only claim "latest" when GitHub also considers this the latest release, so
# re-mirroring an old release does not demote the current one.
status=""
if [ "$prerelease" = "true" ]; then
  status=pre
elif [ "$(gh api "repos/$GITHUB_REPOSITORY/releases/latest" --jq .tag_name 2>/dev/null)" = "$TAG" ]; then
  status=latest
fi

payload=$(jq -n --arg tag "$TAG" --arg name "$name" --arg body "$body" \
  --arg status "$status" \
  '{tag_name: $tag, name: $name, body: $body}
   + (if $status == "" then {} else {release_status: $status} end)')

# --- Create or update the GitCode release ---------------------------------
existing=$(gitcode_release)

if jq -e --arg t "$TAG" '.tag_name == $t' <<<"$existing" >/dev/null 2>&1; then
  echo "Updating existing GitCode release $TAG"
  curl -sS --fail-with-body -X PATCH "$API/releases/$TAG_PATH" \
    --url-query "access_token=$GITCODE_TOKEN" \
    -H 'Content-Type: application/json' \
    --data "$(jq 'del(.tag_name)' <<<"$payload")" >/dev/null
else
  echo "Creating GitCode release for $TAG"
  created=$(curl -sS -X POST "$API/releases" \
    --url-query "access_token=$GITCODE_TOKEN" \
    -H 'Content-Type: application/json' \
    --data "$(jq '. + {target_commitish: "main"}' <<<"$payload")")
  if ! jq -e --arg t "$TAG" '.tag_name == $t' <<<"$created" >/dev/null 2>&1; then
    echo "::error::Failed to create GitCode release: $created"
    exit 1
  fi
fi

# --- Sync assets ----------------------------------------------------------
gitcode_assets=$(gitcode_release | jq -c '.assets // []')

workdir=$(mktemp -d)
trap 'rm -rf "$workdir"' EXIT

# Print "<id>\t<size>" for the GitCode asset with this name, if any.
gitcode_asset() {
  jq -r --arg n "$1" '.[] | select(.name == $n) | "\(.id // "")\t\(.size // "")"' \
    | head -n1
}

# Sync one asset: skip if already present, else download from GitHub and
# upload to GitCode, reporting progress once a minute. Runs in a subshell.
sync_asset() {
  local asset=$1 size=$2 match gid gsize
  local dir="$workdir/$asset.d"
  mkdir -p "$dir"

  match=$(gitcode_asset "$asset" <<<"$gitcode_assets")
  if [ -n "$match" ]; then
    gid=${match%%$'\t'*}
    gsize=${match#*$'\t'}
    if [ -z "$gsize" ] || [ "$gsize" = "$size" ]; then
      echo "✓ already on GitCode"
      return 0
    fi
    echo "↻ size changed ($gsize -> $size); replacing"
    if [ -z "$gid" ]; then
      echo "::error::GitCode did not report an id for $asset; delete it on GitCode by hand, then re-run."
      return 1
    fi
    curl -sS --fail-with-body -X DELETE "$API/releases/$TAG_PATH/attach_files/$gid" \
      --url-query "access_token=$GITCODE_TOKEN" >/dev/null
  fi

  echo "↓ Downloading ($size bytes)"
  gh release download "$TAG" -R "$GITHUB_REPOSITORY" \
    --pattern "$asset" --dir "$dir" --clobber

  # Ask for the pre-signed URL only now: it is short-lived.
  local target
  target=$(curl -sS --fail-with-body -G "$API/releases/$TAG_PATH/upload_url" \
    --data-urlencode "access_token=$GITCODE_TOKEN" \
    --data-urlencode "file_name=$asset") || {
    echo "::error::Could not get a GitCode upload URL for $asset: $target"
    return 1
  }
  local url hdrs=()
  url=$(jq -r '.url // empty' <<<"$target")
  if [ -z "$url" ]; then
    echo "::error::GitCode returned no upload URL for $asset: $target"
    return 1
  fi
  # The URL is signed together with these headers; send them unchanged.
  while IFS= read -r h; do
    hdrs+=(-H "$h")
  done < <(jq -r '.headers // {} | to_entries[] | "\(.key): \(.value)"' <<<"$target")

  echo "↑ Uploading to GitCode"
  # Abort if throughput stays under 10 KB/s for 5 minutes rather than hanging.
  local extra=()
  [ -n "${UPLOAD_MAX_TIME:-}" ] && extra=(--max-time "$UPLOAD_MAX_TIME")
  curl -S -X PUT -T "$dir/$asset" "${hdrs[@]}" "$url" \
    --speed-limit 10240 --speed-time 300 "${extra[@]}" \
    -o "$dir/resp" -w '%{http_code} %{time_total} %{speed_upload}' \
    >"$dir/stats" 2>"$dir/progress" &
  local pid=$! next_report=$((SECONDS + 60)) code secs bps
  while kill -0 "$pid" 2>/dev/null; do
    sleep 5
    if (( SECONDS >= next_report )); then
      next_report=$((next_report + 60))
      # curl's meter: %, total, %, recv, %, sent, avg dl, avg ul, ...
      tr '\r' '\n' <"$dir/progress" | awk 'NF >= 12 && $1 ~ /^[0-9]/ {l=$0} END {
        if (l) { split(l, f); printf "… %s%% of %s sent, avg %s/s, elapsed %s, left %s\n", f[5], f[2], f[8], f[10], f[11] } }'
    fi
  done
  wait "$pid" || true
  read -r code secs bps <"$dir/stats" || true
  echo "HTTP ${code:-000} in ${secs:-?}s ($(awk -v b="${bps:-0}" 'BEGIN{printf "%.1f", b/1024}') KB/s)"
  rm -f "$dir/$asset"
  if [[ "${code:-000}" != 2* ]]; then
    echo "::error::Upload of $asset failed (HTTP ${code:-000}): $(cat "$dir/resp" 2>/dev/null) $(tr '\r' '\n' <"$dir/progress" | grep -v '^ *[0-9% ]' | tail -n3)"
    return 1
  fi

  # Storage notifies GitCode via callback; confirm the asset is now attached.
  local i
  for ((i = 0; i < 12; i++)); do
    match=$(gitcode_release | jq -c '.assets // []' | gitcode_asset "$asset")
    if [ -n "$match" ]; then
      echo "✓ attached to GitCode release"
      return 0
    fi
    sleep 10
  done
  echo "::error::$asset uploaded but never appeared on the GitCode release"
  return 1
}

# Sync every asset concurrently. Each line is prefixed with the asset name.
assets=$(jq -r --arg f "${ASSET_FILTER:-}" \
  '.assets[] | select($f == "" or (.name | test($f))) | "\(.name)\t\(.size)"' <<<"$release")
while IFS=$'\t' read -r asset size; do
  [ -n "$asset" ] || continue
  (
    set -o pipefail
    rc=0
    sync_asset "$asset" "$size" 2>&1 | sed -u "s/^/[$asset] /" || rc=$?
    echo "$rc" >"$workdir/$asset.status"
  ) &
done <<<"$assets"
wait

failed=0
while IFS=$'\t' read -r asset _; do
  [ -n "$asset" ] || continue
  if [ "$(cat "$workdir/$asset.status" 2>/dev/null)" != 0 ]; then
    echo "::error::$asset was not mirrored"
    failed=1
  fi
done <<<"$assets"

exit "$failed"
