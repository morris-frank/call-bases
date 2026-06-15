#!/usr/bin/env bash
#
# deploy.sh - push code + artifacts to the VPS and (re)start the service.
#
# The artifacts are built offline by scaffold/build.sh; this just ships them.
# Usage:
#   infra/deploy.sh user@host [artifacts_dir]
#
# Sends server/ and web/ (small) plus the artifacts (large; rsync resumes/skips
# unchanged files). The server is stateless, so a restart is safe at any time.
set -euo pipefail

HOST="${1:?usage: deploy.sh user@host [artifacts_dir]}"
ARTIFACTS="${2:-artifacts}"
REMOTE_DIR="/opt/call-bases"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "[1/3] code -> ${HOST}:${REMOTE_DIR}"
rsync -avz --delete "${HERE}/server/" "${HOST}:${REMOTE_DIR}/server/"
rsync -avz --delete "${HERE}/web/" "${HOST}:${REMOTE_DIR}/web/"

echo "[2/3] artifacts -> ${HOST}:${REMOTE_DIR}/artifacts (large; resumable)"
rsync -avz --partial --progress "${ARTIFACTS}/" "${HOST}:${REMOTE_DIR}/artifacts/"

echo "[3/3] restart service"
ssh "${HOST}" "sudo systemctl restart call-bases && systemctl --no-pager status call-bases | head -n 5"

echo "deployed."
