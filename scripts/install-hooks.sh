#!/usr/bin/env bash
# Installs the secret-scan hook for this clone (all branches and worktrees).
# Run once after cloning: scripts/install-hooks.sh
#
# The hook goes into the shared hooks folder (git rev-parse --git-common-dir), not a tracked
# core.hooksPath, so it still runs, and fails closed, on checkouts that lack .githooks/.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
chmod +x scripts/*.sh scripts/tests/*.sh .githooks/*

# A tracked core.hooksPath would bypass the shared folder; remove one left by an older install.
git config --unset core.hooksPath 2>/dev/null || true

hooks="$(git rev-parse --path-format=absolute --git-common-dir)/hooks"
mkdir -p "$hooks"
for name in pre-commit pre-merge-commit; do
  install -m 0755 .githooks/pre-commit "$hooks/$name"
done
echo "install-hooks: secret scan installed as pre-commit and pre-merge-commit in $hooks"
