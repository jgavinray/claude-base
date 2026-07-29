#!/usr/bin/env bash
# claude-base gates itself with the same contract it gives every other repo.
set -euo pipefail
exec "$(dirname "$0")/../tests/base-test.sh"
