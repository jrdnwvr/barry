#!/bin/sh
# Put a previous image back. Tags are short commit hashes; see
# `docker images barry-backend` for the three kept.
#
#   sh rollback.sh <tag>
#
set -eu
cd "$(dirname "$0")"
TAG=${1:?usage: rollback.sh <commit tag>}
docker image inspect "barry-backend:$TAG" >/dev/null
docker tag "barry-backend:$TAG" barry-backend:latest
docker compose up -d --no-build
echo "$TAG (rollback)" > state/DEPLOYED
echo "running $TAG; the working tree is still at $(git rev-parse --short HEAD)"
