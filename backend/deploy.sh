#!/bin/sh
# Deploy on the box. Pull, build the image tagged by commit, bring it up,
# wait for the health check, keep the last three commit tags for rollback.
#
#   cd /mnt/user/appdata/barry/backend && sh deploy.sh
#
set -eu
cd "$(dirname "$0")"
git pull --ff-only
SHA=$(git rev-parse --short HEAD)
docker build -t "barry-backend:$SHA" -t barry-backend:latest .
docker compose up -d
for _ in $(seq 1 30); do
  if [ "$(docker inspect --format '{{.State.Health.Status}}' barry-backend 2>/dev/null)" = healthy ]; then
    echo "healthy at $SHA"
    break
  fi
  sleep 3
done
docker inspect --format '{{.State.Health.Status}}' barry-backend | grep -q healthy || { echo "NOT HEALTHY at $SHA; rollback.sh <tag>"; exit 1; }
mkdir -p state && echo "$SHA" > state/DEPLOYED
# Keep the newest three commit tags; the rest go.
docker images barry-backend --format '{{.Tag}}|{{.CreatedAt}}' | grep -v '^latest' | sort -t'|' -k2 -r \
  | awk -F'|' 'NR>3 {print $1}' | while read -r tag; do docker rmi "barry-backend:$tag" >/dev/null 2>&1 || true; done
echo "kept: $(docker images barry-backend --format '{{.Tag}}' | grep -v latest | tr '\n' ' ')"
