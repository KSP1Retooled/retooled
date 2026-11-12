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
# Transient failures (network errors, timeouts, HTTP 408/429/5xx) are retried
# with backoff: API calls up to API_ATTEMPTS times (~5 min), GitHub CLI calls
# up to GH_ATTEMPTS times, and each asset upload up to UPLOAD_ATTEMPTS times.
#
# Required env: GH_TOKEN, GITCODE_TOKEN, GITCODE_OWNER, GITCODE_REPO, TAG,
#               GITHUB_REPOSITORY
# Optional env: WAIT_FOR_ASSETS=true
#               ASSET_FILTER=<regex>  only sync assets whose name matches
#               UPLOAD_MAX_TIME=<s>   cap each upload (for throughput tests)
#               API_ATTEMPTS, GH_ATTEMPTS, UPLOAD_ATTEMPTS  override retries
set -euo pipefail

API="https://api.gitcode.com/api/v5/repos/${GITCODE_OWNER}/${GITCODE_REPO}"
TAG_PATH=$(jq -rn --arg t "$TAG" '$t | @uri')   # tag, escaped for URL paths
API_ATTEMPTS=${API_ATTEMPTS:-8}
GH_ATTEMPTS=${GH_ATTEMPTS:-5}
UPLOAD_ATTEMPTS=${UPLOAD_ATTEMPTS:-3}

# Seconds to wait before retry number $1: 15, 30, 45, then 60 each time.
backoff() {
  local s=$(( $1 * 15 ))
  echo $(( s > 60 ? 60 : s ))
}

# api <METHOD> <path> [curl args...]
# Calls the GitCode API, retrying transient failures. Prints the response
# body. Returns 0 on 2xx, 3 on 404, 4 on any other 4xx, 1 when retries ran out.
api() {
  local method=$1 path=$2 attempt out code body
  shift 2
  for ((attempt = 1; ; attempt++)); do
    out=$(curl -sS -X "$method" "$API$path" \
      --url-query "access_token=$GITCODE_TOKEN" \
      --connect-timeout 30 --max-time 300 \
      -w '\n%{http_code}' "$@") || true
    code=${out##*$'\n'}
    body=${out%$'\n'*}
    [[ "$code" =~ ^[0-9]{3}$ ]] || code=000
    case $code in
      2??) printf '%s' "$body"; return 0 ;;
      404) printf '%s' "$body"; return 3 ;;
      408 | 429 | 5?? | 000) ;;   # transient: retry
      *) printf '%s' "$body"; return 4 ;;
    esac
    if (( attempt >= API_ATTEMPTS )); then
      echo "::warning::GitCode $method $path failed after $attempt attempts (HTTP $code): ${body:0:300}" >&2
      printf '%s' "$body"
      return 1
    fi
    local wait_s
    wait_s=$(backoff "$attempt")
    echo "GitCode $method $path: HTTP $code; retrying in ${wait_s}s ($attempt/$API_ATTEMPTS)" >&2
    sleep "$wait_s"
  done
}

# retry <attempts> <command...>: re-run a command until it succeeds.
retry() {
  local n=$1 i wait_s
  shift
  for ((i = 1; ; i++)); do
    "$@" && return 0
    (( i >= n )) && return 1
    wait_s=$(backoff "$i")
    echo "'$1' failed; retrying in ${wait_s}s ($i/$n)" >&2
    sleep "$wait_s"
  done
}

gh_release() {
  gh release view "$TAG" -R "$GITHUB_REPOSITORY" \
    --json name,body,isPrerelease,assets
}

asset_fingerprint() {
  retry "$GH_ATTEMPTS" gh_release | jq -c '[.assets[] | {name, size}] | sort_by(.name)'
}

# Print the GitCode release JSON for $TAG; fails unless GitCode returned it.
gitcode_release() {
  local r
  r=$(api GET "/releases/tags/$TAG_PATH") || return $?
  jq -e --arg t "$TAG" '.tag_name == $t' <<<"$r" >/dev/null 2>&1 || return 3
  printf '%s' "$r"
}

# Print the release's asset list, or fail. Never mistakes an error for [].
gitcode_assets_now() {
  gitcode_release | jq -c '.assets // []'
}

# Print "<id>\t<size>" for the asset named $1 in the list on stdin, if any.
gitcode_asset() {
  jq -r --arg n "$1" '.[] | select(.name == $n) | "\(.id // "")\t\(.size // "")"' \
    | head -n1
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
    out=$(api GET /tags --url-query "per_page=100" --url-query "page=$page") || return 1
    jq -e --arg t "$TAG" 'any(.[]; .name == $t)' <<<"$out" >/dev/null 2>&1 && return 0
    # Stop at the last (short or empty) page, or on a non-array body.
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

release=$(retry "$GH_ATTEMPTS" gh_release)
name=$(jq -r '.name // empty' <<<"$release")
body=$(jq -r '.body // empty' <<<"$release")
prerelease=$(jq -r '.isPrerelease' <<<"$release")
name="${name:-$TAG}"
body="${body:-Release $TAG}"   # name and body are required by GitCode

# GitCode has release_status (pre | latest) instead of a prerelease flag.
# Only claim "latest" when GitHub also considers this the latest release, so
# re-mirroring an old release does not demote the current one.
gh_latest_tag() {
  gh api "repos/$GITHUB_REPOSITORY/releases/latest" --jq .tag_name
}
status=""
if [ "$prerelease" = "true" ]; then
  status=pre
elif [ "$(retry "$GH_ATTEMPTS" gh_latest_tag 2>/dev/null)" = "$TAG" ]; then
  status=latest
fi

payload=$(jq -n --arg tag "$TAG" --arg name "$name" --arg body "$body" \
  --arg status "$status" \
  '{tag_name: $tag, name: $name, body: $body}
   + (if $status == "" then {} else {release_status: $status} end)')

# --- Create or update the GitCode release ---------------------------------
rc=0
gitcode_release >/dev/null || rc=$?
case $rc in
  0)
    echo "Updating existing GitCode release $TAG"
    if ! out=$(api PATCH "/releases/$TAG_PATH" \
      -H 'Content-Type: application/json' \
      --data "$(jq 'del(.tag_name)' <<<"$payload")"); then
      echo "::error::Failed to update GitCode release: $out"
      exit 1
    fi
    ;;
  3 | 4)
    echo "Creating GitCode release for $TAG"
    if ! out=$(api POST /releases \
      -H 'Content-Type: application/json' \
      --data "$(jq '. + {target_commitish: "main"}' <<<"$payload")"); then
      # A retried POST can fail because an earlier attempt already went
      # through (and only its response was lost); check before giving up.
      if gitcode_release >/dev/null; then
        echo "Release exists after all; continuing"
      else
        echo "::error::Failed to create GitCode release: $out"
        exit 1
      fi
    fi
    ;;
  *)
    echo "::error::Could not reach GitCode to look up release $TAG"
    exit 1
    ;;
esac

# --- Sync assets ----------------------------------------------------------
if ! gitcode_assets=$(gitcode_assets_now); then
  echo "::error::Could not read the asset list of GitCode release $TAG"
  exit 1
fi

workdir=$(mktemp -d)
trap 'rm -rf "$workdir"' EXIT

# True if the asset is attached on GitCode (with the expected size, when
# GitCode reports one).
asset_attached() {
  local asset=$1 size=$2 match gsize
  match=$(gitcode_assets_now | gitcode_asset "$asset") || return 1
  [ -n "$match" ] || return 1
  gsize=${match#*$'\t'}
  [ -z "$gsize" ] || [ "$gsize" = "$size" ]
}

# One upload attempt: fetch a fresh pre-signed URL (they are short-lived)
# and PUT the file there, reporting progress once a minute.
upload_once() {
  local asset=$1 file=$2 dir=$3 target url h
  local hdrs=() extra=()
  if ! target=$(api GET "/releases/$TAG_PATH/upload_url" --url-query "file_name=$asset"); then
    echo "Could not get an upload URL: ${target:0:300}"
    return 1
  fi
  url=$(jq -r '.url // empty' <<<"$target" 2>/dev/null || true)
  if [ -z "$url" ]; then
    echo "GitCode returned no upload URL: ${target:0:300}"
    return 1
  fi
  # The URL is signed together with these headers; send them unchanged.
  while IFS= read -r h; do
    hdrs+=(-H "$h")
  done < <(jq -r '.headers // {} | to_entries[] | "\(.key): \(.value)"' <<<"$target")

  # Abort if throughput stays under 10 KB/s for 5 minutes rather than hanging.
  [ -n "${UPLOAD_MAX_TIME:-}" ] && extra=(--max-time "$UPLOAD_MAX_TIME")
  : >"$dir/stats"
  curl -S -X PUT -T "$file" "${hdrs[@]}" "$url" \
    --connect-timeout 30 --speed-limit 10240 --speed-time 300 "${extra[@]}" \
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
  if [[ "${code:-000}" != 2* ]]; then
    echo "Upload failed (HTTP ${code:-000}): $(head -c 300 "$dir/resp" 2>/dev/null) $(tr '\r' '\n' <"$dir/progress" | grep -v '^ *[0-9% ]' | tail -n3)"
    return 1
  fi
}

# Sync one asset: skip if already present, else download from GitHub and
# upload to GitCode, retrying failed uploads. Runs in a subshell.
sync_asset() {
  local asset=$1 size=$2 match gid gsize rc
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
    # 404 means an earlier (retried) attempt already deleted it.
    rc=0
    api DELETE "/releases/$TAG_PATH/attach_files/$gid" >/dev/null || rc=$?
    if [ "$rc" != 0 ] && [ "$rc" != 3 ]; then
      echo "::error::Could not delete the old $asset from GitCode"
      return 1
    fi
  fi

  echo "↓ Downloading ($size bytes)"
  if ! retry "$GH_ATTEMPTS" gh release download "$TAG" -R "$GITHUB_REPOSITORY" \
    --pattern "$asset" --dir "$dir" --clobber; then
    echo "::error::Could not download $asset from GitHub"
    return 1
  fi

  local attempt wait_s uploaded=false
  for ((attempt = 1; attempt <= UPLOAD_ATTEMPTS; attempt++)); do
    if (( attempt > 1 )); then
      wait_s=$(backoff "$attempt")
      echo "Retrying upload in ${wait_s}s ($attempt/$UPLOAD_ATTEMPTS)"
      sleep "$wait_s"
      # The previous PUT may have landed with only its response lost.
      if asset_attached "$asset" "$size"; then
        echo "✓ previous attempt reached GitCode after all"
        rm -f "$dir/$asset"
        return 0
      fi
    fi
    echo "↑ Uploading to GitCode (attempt $attempt/$UPLOAD_ATTEMPTS)"
    upload_once "$asset" "$dir/$asset" "$dir" && { uploaded=true; break; }
  done
  rm -f "$dir/$asset"
  if [ "$uploaded" != true ]; then
    echo "::error::Upload of $asset failed after $UPLOAD_ATTEMPTS attempts"
    return 1
  fi

  # Storage notifies GitCode via callback; confirm the asset is now attached.
  local i
  for ((i = 0; i < 12; i++)); do
    if asset_attached "$asset" "$size"; then
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
