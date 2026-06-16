#!/usr/bin/env bash
set -euo pipefail

cd /opt/call-bases

git fetch origin main
git reset --hard origin/main

sudo systemctl daemon-reload
sudo systemctl restart call-bases-caddy
sudo systemctl restart call-bases

sudo systemctl restart call-bases.service
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy