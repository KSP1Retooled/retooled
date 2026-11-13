#!/usr/bin/env bash
# Push this repository's branches and tags to GitCode over HTTPS, so the tag a
# release is attached to always exists there before the release is mirrored.
#
# Authenticates with the GitCode personal access token (the same one the
# release API uses): GitCode accepts it as the password for HTTPS git, with
# the token owner's login as the username.
#
# Branches and tags are force-updated to match GitHub; refs that exist only on
# GitCode are left alone (nothing is deleted). The tags push is required; a
# rejected branch (for example a protected branch on GitCode) is reported as a
# warning so it does not block the release.
#
# Run from a full clone (actions/checkout with fetch-depth: 0), after the
# workflow's TCP tuning step so pushes get the same tuned connection.
#
# Required env: GITCODE_TOKEN, GITCODE_OWNER, GITCODE_REPO
# Optional env: TAG  check that this tag exists on GitCode afterwards
set -euo pipefail

remote="https://gitcode.com/${GITCODE_OWNER}/${GITCODE_REPO}.git"

# retry <attempts> <command...>, waiting 15 s, 30 s, 45 s... between tries.
retry() {
  local n=$1 i
  shift
  for ((i = 1; ; i++)); do
    "$@" && return 0
    (( i >= n )) && return 1
    echo "'$1' failed; retrying in $((i * 15))s ($i/$n)" >&2
    sleep $((i * 15))
  done
}

# The token owner's login, used as the HTTPS git username.
gitcode_login() {
  curl -sS --fail --connect-timeout 30 --max-time 60 -G \
    https://api.gitcode.com/api/v5/user \
    --data-urlencode "access_token=$GITCODE_TOKEN" | jq -er '.login'
}
if ! GITCODE_USER=$(retry 4 gitcode_login); then
  echo "::error::Could not look up the GitCode account for the GITEEPAT token"
  exit 1
fi
export GITCODE_USER GITCODE_TOKEN
echo "Pushing as GitCode user $GITCODE_USER"

# git_gitcode <git args...>: run git against GitCode with the token supplied
# by a credential helper that reads the environment, so it never appears in a
# URL, the git config or the log.
git_gitcode() {
  git \
    -c credential.helper= \
    -c 'credential.helper=!f() { echo "username=$GITCODE_USER"; echo "password=$GITCODE_TOKEN"; }; f' \
    -c http.postBuffer=524288000 \
    -c http.lowSpeedLimit=1000 -c http.lowSpeedTime=300 \
    "$@"
}

# Make sure every branch and tag from GitHub is present locally.
if [ "$(git rev-parse --is-shallow-repository)" = true ]; then
  retry 3 git fetch --unshallow --tags origin
fi
retry 3 git fetch --prune --tags origin '+refs/heads/*:refs/remotes/origin/*'
# origin/HEAD is a pointer, not a branch; keep it from becoming refs/heads/HEAD.
git remote set-head origin --delete 2>/dev/null || true

echo "Pushing tags to $remote"
if ! retry 3 git_gitcode push --force "$remote" 'refs/tags/*:refs/tags/*'; then
  echo "::error::Could not push tags to GitCode. Check that the GITEEPAT token has write access to $GITCODE_OWNER/$GITCODE_REPO, and that the repository is not a read-only pull mirror."
  exit 1
fi

echo "Pushing branches to $remote"
if ! retry 3 git_gitcode push --force "$remote" 'refs/remotes/origin/*:refs/heads/*'; then
  echo "::warning::Some branches could not be pushed to GitCode (protected branch?); tags were synced."
fi

if [ -n "${TAG:-}" ]; then
  if retry 3 git_gitcode ls-remote --exit-code "$remote" "refs/tags/$TAG" >/dev/null; then
    echo "Tag $TAG is on GitCode"
  else
    echo "::error::Tag $TAG is still missing on GitCode after the push"
    exit 1
  fi
fi
