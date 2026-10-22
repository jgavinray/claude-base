#!/usr/bin/env bash
# claude-base gates itself with the same contract it gives every other repo.
# This repo is public: the leak gate runs first (no private or Tailscale IP
# address, no other-engineer name in any tracked file), then the regression suite.
set -euo pipefail
here="$(dirname "$0")"
python3 "$here/../tests/leak_check.py"
exec "$here/../tests/base-test.sh"
