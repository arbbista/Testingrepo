#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# List the IDMC check-in commits between two Git revisions, oldest first.
#
#   scripts/idmc-commits.sh <from> <to>
#
# Merge commits are skipped, and so are commits that only change pipeline or
# documentation files (.github/, scripts/, docs/, *.md). What is left are the
# commits IDMC created when developers clicked "Check In" - these are the ones
# the pipeline deploys, in order.
# -----------------------------------------------------------------------------
set -euo pipefail

if [ $# -ne 2 ]; then
  echo "Usage: $0 <from> <to>" >&2
  exit 2
fi

git rev-list --reverse --no-merges "$1..$2" -- . \
  ':(exclude).github' \
  ':(exclude)scripts' \
  ':(exclude)docs' \
  ':(exclude)*.md'
