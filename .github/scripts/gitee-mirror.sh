#!/usr/bin/env bash
# Mirror a GitHub release (metadata + assets) to Gitee.
#
# Idempotent: re-running only uploads assets that are missing on Gitee or
# whose size differs from the GitHub copy.
#
# Required env: GH_TOKEN, GITEE_TOKEN, GITEE_OWNER, GITEE_REPO, TAG,
#               GITHUB_REPOSITORY
# Optional env: WAIT_FOR_ASSETS=true
#               ASSET_FILTER=<regex>  only sync assets whose name matches
set -euo pipefail

API="https://gitee.com/api/v5/repos/${GITEE_OWNER}/${GITEE_REPO}"

gh_release() {
  gh release view "$TAG" -R "$GITHUB_REPOSITORY" \
    --json name,body,isPrerelease,assets
}

asset_fingerprint() {
  gh_release | jq -c '[.assets[] | {name, size}] | sort_by(.name)'
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

# --- Wait for Gitee's repository mirror to pick up the tag ----------------
# The Gitee repo pulls git history from GitHub on its own; the release must
# be attached to a tag that already exists there.
for ((i = 0; ; i++)); do
  code=$(curl -sS -o /dev/null -w '%{http_code}' -G "$API/tags/$TAG" \
    --data-urlencode "access_token=$GITEE_TOKEN")
  # Fall back to scanning the tag list if the single-tag endpoint is missing.
  if [ "$code" != 200 ]; then
    curl -sS -G "$API/tags" --data-urlencode "access_token=$GITEE_TOKEN" \
      --data-urlencode "per_page=100" --data-urlencode "sort=updated" \
      --data-urlencode "direction=desc" \
      | jq -e --arg t "$TAG" 'any(.[]; .name == $t)' >/dev/null && code=200
  fi
  [ "$code" = 200 ] && { echo "Tag $TAG present on Gitee"; break; }
  if [ "$i" -ge 30 ]; then
    echo "::error::Tag $TAG did not appear on Gitee after 30 minutes. Sync the Gitee repository mirror, then re-run this workflow."
    exit 1
  fi
  echo "Waiting for tag $TAG to be mirrored to Gitee..."
  sleep 60
done

release=$(gh_release)
name=$(jq -r '.name // empty' <<<"$release")
body=$(jq -r '.body // empty' <<<"$release")
prerelease=$(jq -r '.isPrerelease' <<<"$release")
name="${name:-$TAG}"
body="${body:-Release $TAG}"   # Gitee rejects an empty body

# --- Create or update the Gitee release -----------------------------------
existing=$(curl -sS -G "$API/releases/tags/$TAG" \
  --data-urlencode "access_token=$GITEE_TOKEN")

if [ "$(jq -r '.id // empty' <<<"$existing" 2>/dev/null)" ]; then
  release_id=$(jq -r '.id' <<<"$existing")
  echo "Updating existing Gitee release $release_id"
  curl -sSf -X PATCH "$API/releases/$release_id" \
    --data-urlencode "access_token=$GITEE_TOKEN" \
    --data-urlencode "tag_name=$TAG" \
    --data-urlencode "name=$name" \
    --data-urlencode "body=$body" \
    --data-urlencode "prerelease=$prerelease" >/dev/null
else
  echo "Creating Gitee release for $TAG"
  created=$(curl -sS -X POST "$API/releases" \
    --data-urlencode "access_token=$GITEE_TOKEN" \
    --data-urlencode "tag_name=$TAG" \
    --data-urlencode "name=$name" \
    --data-urlencode "body=$body" \
    --data-urlencode "prerelease=$prerelease" \
    --data-urlencode "target_commitish=main")
  release_id=$(jq -r '.id // empty' <<<"$created")
  if [ -z "$release_id" ]; then
    echo "::error::Failed to create Gitee release: $created"
    exit 1
  fi
fi

# --- Sync assets ----------------------------------------------------------
gitee_assets=$(curl -sSf -G "$API/releases/$release_id/attach_files" \
  --data-urlencode "access_token=$GITEE_TOKEN" \
  --data-urlencode "per_page=100")

workdir=$(mktemp -d)
trap 'rm -rf "$workdir"' EXIT

# Sync one asset: skip if already present, else download from GitHub and
# upload to Gitee, reporting progress once a minute. Runs in a subshell.
sync_asset() {
  local asset=$1 size=$2 match gid gsize
  local dir="$workdir/$asset.d"
  mkdir -p "$dir"

  match=$(jq -r --arg n "$asset" '.[] | select(.name == $n) | "\(.id)\t\(.size // "")"' \
    <<<"$gitee_assets" | head -n1)
  if [ -n "$match" ]; then
    gid=${match%%$'\t'*}
    gsize=${match#*$'\t'}
    if [ -z "$gsize" ] || [ "$gsize" = "$size" ]; then
      echo "✓ already on Gitee"
      return 0
    fi
    echo "↻ size changed ($gsize -> $size); replacing"
    curl -sSf -X DELETE -G "$API/releases/$release_id/attach_files/$gid" \
      --data-urlencode "access_token=$GITEE_TOKEN" >/dev/null
  fi

  echo "↓ Downloading ($size bytes)"
  gh release download "$TAG" -R "$GITHUB_REPOSITORY" \
    --pattern "$asset" --dir "$dir" --clobber

  echo "↑ Uploading to Gitee"
  # Abort if throughput stays under 10 KB/s for 5 minutes rather than hanging.
  # UPLOAD_MAX_TIME (seconds) caps each upload; used for throughput tests.
  local extra=()
  [ -n "${UPLOAD_MAX_TIME:-}" ] && extra=(--max-time "$UPLOAD_MAX_TIME")
  curl -S -X POST "$API/releases/$release_id/attach_files" \
    -F "access_token=$GITEE_TOKEN" \
    -F "file=@$dir/$asset" \
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
}

# Uploads to Gitee from outside China crawl at ~20 KB/s per connection, so
# sync every asset concurrently. Each line is prefixed with the asset name.
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
