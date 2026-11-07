#!/usr/bin/env bash
# Points this clone's git hooks at the tracked .githooks/ folder.
# Run once after cloning: scripts/install-hooks.sh
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
chmod +x .githooks/* scripts/*.sh
git config core.hooksPath .githooks
echo "install-hooks: core.hooksPath set to .githooks (pre-commit secret scan is active)"
