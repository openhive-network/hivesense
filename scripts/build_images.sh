#!/bin/sh

GIT_COMMIT_SHA=$(git -C "$(git rev-parse --show-superproject-working-tree --show-toplevel | head -1)" rev-parse HEAD || true)
if [ -z "$GIT_COMMIT_SHA" ]; then
  GIT_COMMIT_SHA="[unknown]"
fi

print_help () {
cat <<-EOF
  Usage: $0 <image> <local-directory> [OPTION[=VALUE]]...

  Exports data from a Docker image to a local directory
  OPTIONS:
    --push                 Push built images to registry
    --tag=TAG_NAME         Name of tag used for hivesense and hivesense_rewriter images
    --help,-h,-?           Display this help screen and exit
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --tag=*)
        TAG="${1#*=}"
        ;;
    --push)
        PUSH=1
        ;;
    --help|-h|-\?)
        print_help
        exit 0
        ;;
    -*)
        echo "ERROR: '$1' is not a valid option"
        exit 1
        ;;
    *)
        echo "ERROR: '$1' is not a valid positional argument"
    esac
    shift
done

TAG=${TAG:-$(echo "$GIT_COMMIT_SHA" | cut -c1-8)}

# Resolve API version from git tags for OpenAPI spec injection
git -C "$(git rev-parse --show-superproject-working-tree --show-toplevel | head -1)" fetch --tags --quiet 2>/dev/null || true
API_VERSION="$(git -C "$(git rev-parse --show-superproject-working-tree --show-toplevel | head -1)" describe --tags --abbrev=0 2>/dev/null || echo dev)"

if [ -z "$TAG" ]; then
  echo "No tag, please pass it at first argument" >&2
  exit 1
fi

set -eu pipefail

SCRIPTPATH="$( cd -- "$(dirname "$0")" >/dev/null 2>&1 ; pwd -P )"

# Enable BuildKit for better caching and performance
export DOCKER_BUILDKIT=1

# Try to pull latest images for cache (ignore failures if images don't exist)
echo "Pulling latest images for cache..."
docker pull "registry.gitlab.syncad.com/hive/hivesense:develop" 2>/dev/null || true
docker pull "registry.gitlab.syncad.com/hive/hivesense/postgrest-rewriter:develop" 2>/dev/null || true
docker pull "registry.gitlab.syncad.com/hive/hivesense/syncer:develop" 2>/dev/null || true
docker pull "registry.gitlab.syncad.com/hive/hivesense/pca:develop" 2>/dev/null || true

# Build with cache-from and inline cache export for registry caching
echo "Building hivesense..."
docker build \
  --cache-from "registry.gitlab.syncad.com/hive/hivesense:develop" \
  --build-arg BUILDKIT_INLINE_CACHE=1 \
  --build-arg API_VERSION="$API_VERSION" \
  --build-arg GIT_COMMIT_SHA="$GIT_COMMIT_SHA" \
  -t "registry.gitlab.syncad.com/hive/hivesense:${TAG}" \
  "${SCRIPTPATH}/.."

echo "Building postgrest-rewriter..."
docker build \
  --cache-from "registry.gitlab.syncad.com/hive/hivesense/postgrest-rewriter:develop" \
  --build-arg BUILDKIT_INLINE_CACHE=1 \
  -t "registry.gitlab.syncad.com/hive/hivesense/postgrest-rewriter:${TAG}" \
  -f "${SCRIPTPATH}/../Dockerfile.rewriter" \
  "${SCRIPTPATH}/.."

echo "Building syncer..."
docker build \
  --cache-from "registry.gitlab.syncad.com/hive/hivesense/syncer:develop" \
  --build-arg BUILDKIT_INLINE_CACHE=1 \
  -t "registry.gitlab.syncad.com/hive/hivesense/syncer:${TAG}" \
  -f "${SCRIPTPATH}/../Dockerfile.syncer" \
  "${SCRIPTPATH}/.."

echo "Building pca..."
docker build \
  --cache-from "registry.gitlab.syncad.com/hive/hivesense/pca:develop" \
  --build-arg BUILDKIT_INLINE_CACHE=1 \
  -t "registry.gitlab.syncad.com/hive/hivesense/pca:${TAG}" \
  -f "${SCRIPTPATH}/../Dockerfile.pca" \
  "${SCRIPTPATH}/.."

echo "Build images tag ${TAG}"

if [ -n "${PUSH:-}" ]; then
  docker push "registry.gitlab.syncad.com/hive/hivesense:${TAG}"
  docker push "registry.gitlab.syncad.com/hive/hivesense/postgrest-rewriter:${TAG}"
  docker push "registry.gitlab.syncad.com/hive/hivesense/syncer:${TAG}"
  docker push "registry.gitlab.syncad.com/hive/hivesense/pca:${TAG}"
  echo "Pushed images tag ${TAG}"

  # Add 'latest' tags on develop branch
  if [ "${CI_COMMIT_BRANCH:-}" = "${CI_DEFAULT_BRANCH:-develop}" ]; then
    echo "Tagging images with 'latest' tag for develop branch..."
    docker tag "registry.gitlab.syncad.com/hive/hivesense:${TAG}" "registry.gitlab.syncad.com/hive/hivesense:latest"
    docker tag "registry.gitlab.syncad.com/hive/hivesense/postgrest-rewriter:${TAG}" "registry.gitlab.syncad.com/hive/hivesense/postgrest-rewriter:latest"
    docker tag "registry.gitlab.syncad.com/hive/hivesense/syncer:${TAG}" "registry.gitlab.syncad.com/hive/hivesense/syncer:latest"
    docker tag "registry.gitlab.syncad.com/hive/hivesense/pca:${TAG}" "registry.gitlab.syncad.com/hive/hivesense/pca:latest"
    docker push "registry.gitlab.syncad.com/hive/hivesense:latest"
    docker push "registry.gitlab.syncad.com/hive/hivesense/postgrest-rewriter:latest"
    docker push "registry.gitlab.syncad.com/hive/hivesense/syncer:latest"
    docker push "registry.gitlab.syncad.com/hive/hivesense/pca:latest"
    echo "Pushed 'latest' tags"
  fi

  # Add version tags on protected tags
  if [ -n "${CI_COMMIT_TAG:-}" ] && [ "${CI_COMMIT_REF_PROTECTED:-}" = "true" ]; then
    echo "Tagging images with version tag '${CI_COMMIT_TAG}'..."
    docker tag "registry.gitlab.syncad.com/hive/hivesense:${TAG}" "registry.gitlab.syncad.com/hive/hivesense:${CI_COMMIT_TAG}"
    docker tag "registry.gitlab.syncad.com/hive/hivesense/postgrest-rewriter:${TAG}" "registry.gitlab.syncad.com/hive/hivesense/postgrest-rewriter:${CI_COMMIT_TAG}"
    docker tag "registry.gitlab.syncad.com/hive/hivesense/syncer:${TAG}" "registry.gitlab.syncad.com/hive/hivesense/syncer:${CI_COMMIT_TAG}"
    docker tag "registry.gitlab.syncad.com/hive/hivesense/pca:${TAG}" "registry.gitlab.syncad.com/hive/hivesense/pca:${CI_COMMIT_TAG}"
    docker push "registry.gitlab.syncad.com/hive/hivesense:${CI_COMMIT_TAG}"
    docker push "registry.gitlab.syncad.com/hive/hivesense/postgrest-rewriter:${CI_COMMIT_TAG}"
    docker push "registry.gitlab.syncad.com/hive/hivesense/syncer:${CI_COMMIT_TAG}"
    docker push "registry.gitlab.syncad.com/hive/hivesense/pca:${CI_COMMIT_TAG}"
    echo "Pushed version tags '${CI_COMMIT_TAG}'"
  fi
fi
