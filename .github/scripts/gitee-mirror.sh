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
failed=0

while IFS=$'\t' read -r asset size; do
  match=$(jq -r --arg n "$asset" '.[] | select(.name == $n) | "\(.id)\t\(.size // "")"' \
    <<<"$gitee_assets" | head -n1)
  if [ -n "$match" ]; then
    gid=${match%%$'\t'*}
    gsize=${match#*$'\t'}
    if [ -z "$gsize" ] || [ "$gsize" = "$size" ]; then
      echo "✓ $asset already on Gitee"
      continue
    fi
    echo "↻ $asset size changed ($gsize -> $size); replacing"
    curl -sSf -X DELETE -G "$API/releases/$release_id/attach_files/$gid" \
      --data-urlencode "access_token=$GITEE_TOKEN" >/dev/null
  fi

  echo "↓ Downloading $asset ($size bytes)"
  gh release download "$TAG" -R "$GITHUB_REPOSITORY" \
    --pattern "$asset" --dir "$workdir" --clobber

  echo "↑ Uploading $asset to Gitee"
  # Abort if throughput stays under 10 KB/s for 5 minutes rather than hanging.
  resp=$(curl -sS -X POST "$API/releases/$release_id/attach_files" \
    -F "access_token=$GITEE_TOKEN" \
    -F "file=@$workdir/$asset" \
    --speed-limit 10240 --speed-time 300 \
    -w '\n%{http_code} %{time_total} %{speed_upload}') || true
  stats=${resp##*$'\n'}
  read -r code secs bps <<<"$stats"
  echo "  HTTP $code in ${secs}s ($(awk -v b="$bps" 'BEGIN{printf "%.1f", b/1024}') KB/s)"
  if [[ "$code" != 2* ]]; then
    echo "::error::Upload of $asset failed (HTTP $code): ${resp%$'\n'*}"
    failed=1
  fi
  rm -f "$workdir/$asset"
done < <(jq -r --arg f "${ASSET_FILTER:-}" \
  '.assets[] | select($f == "" or (.name | test($f))) | "\(.name)\t\(.size)"' <<<"$release")

exit "$failed"
