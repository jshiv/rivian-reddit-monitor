#!/bin/sh
# install_deps task: bootstrap the runtime so the rest of the pipeline
# can assume python3, pip3, jq, and curl are on PATH.
#
# Idempotent — re-runs are cheap. We detect the container's package
# manager (apk for the stock alpine cronicled image, apt-get for any
# debian-based custom image) and install only what's missing.
# Local macOS dev usually has python3 already and no apk/apt; the
# missing-pkg-mgr branch is the explicit failure for that case so
# we don't silently skip on a half-broken host.
#
# Why not bake everything into the cronicled image? Two reasons:
#   1. The pipeline's deps live with the pipeline. Adding a new
#      package here is a git-commit, not an image rebuild.
#   2. Different projects on the same cluster can have different
#      runtime needs without coupling them through one image.
#
# Cost: ~30s on first run, ~0s on cache hits.

set -eu

need() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "  missing: $1"
    return 1
  fi
}

missing=""
for pkg in python3 pip3 jq curl; do
  if ! command -v "$pkg" >/dev/null 2>&1; then
    missing="${missing} ${pkg}"
  fi
done

if [ -n "${missing}" ]; then
  echo ">>> packages missing:${missing}"
  if command -v apk >/dev/null 2>&1; then
    echo ">>> apk add python3 py3-pip jq curl"
    apk add --no-cache python3 py3-pip jq curl
  elif command -v apt-get >/dev/null 2>&1; then
    echo ">>> apt-get install python3 python3-pip jq curl"
    apt-get update -qq
    apt-get install -y --no-install-recommends python3 python3-pip jq curl
  else
    echo "FATAL: no supported package manager (tried apk, apt-get)" >&2
    echo "       install python3, pip3, jq, curl manually or use a base image that includes them" >&2
    exit 1
  fi
else
  echo ">>> all required tools already on PATH"
fi

echo ">>> $(python3 --version)"
echo ">>> $(pip3 --version)"
echo ">>> pip3 install --user -r requirements.txt"
pip3 install --user --no-warn-script-location -r requirements.txt

echo ">>> setup complete"
