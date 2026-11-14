#!/usr/bin/env bash
# Deploys the latest main branch of the LPO web app on the server.
# Called by GitHub Actions over SSH (see .github/workflows/deploy.yml); can also be run by hand:
#   bash /srv/lpo/lpo-core/scripts/deploy.sh
#
# Caddy serves dist/. The new build is made in dist.next/ and swapped in at the end, so visitors
# never see a half-built site. Previous asset files are kept, so people with the old version open
# can still load its pages until they refresh.
set -euo pipefail

# Everything runs inside main(): bash reads the whole function before starting, so the
# git reset below can safely replace this file while it runs.
main() {

  APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  BRANCH="${DEPLOY_BRANCH:-main}"
  cd "$APP_DIR"

  # SSH deploys run in a non-login shell; load nvm if Node was installed that way.
  if ! command -v npm >/dev/null && [[ -s "$HOME/.nvm/nvm.sh" ]]; then
    # shellcheck disable=SC1091
    source "$HOME/.nvm/nvm.sh"
  fi

  exec 9>"$APP_DIR/.deploy.lock"
  flock -n 9 || { echo "Another deploy is running."; exit 1; }

  step() { printf '\n==> %s\n' "$*"; }

  step "Fetching $BRANCH"
  git fetch --prune origin "$BRANCH"
  OLD_REV="$(git rev-parse HEAD)"
  git reset --hard "origin/$BRANCH"
  NEW_REV="$(git rev-parse HEAD)"
  echo "    $OLD_REV -> $NEW_REV"

  # The API URL is baked into the build; refuse to build against localhost by mistake.
  # It comes from .env.production (or .env.production.local, which wins). Both live only on the server:
  # they are git-ignored, so the git reset above leaves them alone.
  local env_files=() f
  for f in .env.production.local .env.production; do [[ -f $f ]] && env_files+=("$f"); done
  if [[ ${#env_files[@]} -eq 0 ]] || ! grep -Eq '^[[:space:]]*VITE_API_BASE_URL=["'\'']?https://' "${env_files[@]}"; then
    echo "Set VITE_API_BASE_URL=https://api.lpoph.com/api/v1 in $APP_DIR/.env.production."
    exit 1
  fi

  step "Installing dependencies"
  npm ci --no-audit --no-fund --loglevel=error

  step "Type-checking and building"
  npx tsc --noEmit
  rm -rf dist.next
  npx vite build --outDir dist.next --emptyOutDir

  step "Publishing"
  if [[ -d dist/assets ]]; then
    # Keep old hashed files for open tabs (-p keeps their age). `cp -n` exits 1 when it skips a file
    # that already exists (unchanged hashes do), so that status is expected, not an error.
    cp -rnp dist/assets/. dist.next/assets/ 2>/dev/null || true
    find dist.next/assets -type f -mtime +14 -delete  # but not forever
  fi
  rm -rf dist.old
  [[ -d dist ]] && mv dist dist.old
  mv dist.next dist
  rm -rf dist.old

  printf '\nDeployed %s\n' "$(git log -1 --format='%h %s')"
}

main "$@"
exit $?
