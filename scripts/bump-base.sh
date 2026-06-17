#!/usr/bin/env bash
# bump-base.sh — atomically advance the outer repo's `base` submodule pointer.
#
# WHY THIS EXISTS:
# The base/ submodule and the outer repo's recorded pointer to it are two
# separate things. Committing inside base/ does NOT update the outer pointer;
# that needs a separate `git add base` in the outer repo. Doing it by hand
# drifts easily (you can commit a stale or unpushed base SHA). This script
# does the whole sequence in the correct order, every time.
#
# USAGE (run from anywhere in the repo):
#   scripts/bump-base.sh "outer commit message"
# Assumes you have ALREADY committed your changes inside base/.
# It will: verify base is clean, push base, bump+commit the outer pointer.
# Pushing the outer repo is left to you (`git push`), and push.recurseSubmodules
# =check will refuse if base isn't on origin.

set -euo pipefail

MSG="${1:-}"
if [[ -z "$MSG" ]]; then
    echo "usage: scripts/bump-base.sh \"outer commit message\"" >&2
    exit 2
fi

# Resolve repo root so the script works from any subdirectory.
ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"

# 1. base/ must have no uncommitted changes — commit those inside base/ first.
if [[ -n "$(git -C base status --porcelain)" ]]; then
    echo "ERROR: base/ has uncommitted changes. Commit them inside base/ first:" >&2
    git -C base status --short >&2
    exit 1
fi

BASE_SHA="$(git -C base rev-parse HEAD)"
BASE_BRANCH="$(git -C base branch --show-current || echo 'DETACHED')"
echo "base HEAD: ${BASE_SHA:0:7} on ${BASE_BRANCH}"

# 2. Push base so the commit the outer pointer references actually exists on origin.
echo "Pushing base/ ..."
git -C base push

# 3. Bump the outer pointer to the freshly-pushed base HEAD.
git add base
if git diff --cached --quiet -- base; then
    echo "Outer pointer already at ${BASE_SHA:0:7} — nothing to bump."
    exit 0
fi
git commit -m "$MSG"

# 4. Confirm pointer == base HEAD.
RECORDED="$(git ls-tree HEAD base | awk '{print $3}')"
if [[ "$RECORDED" != "$BASE_SHA" ]]; then
    echo "ERROR: recorded pointer ${RECORDED:0:7} != base HEAD ${BASE_SHA:0:7}" >&2
    exit 1
fi
echo "OK: outer pointer now at ${BASE_SHA:0:7}. Run 'git push' to publish the outer repo."
