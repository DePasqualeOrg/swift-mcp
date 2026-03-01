#!/usr/bin/env bash
# Run Swift build and tests in a Linux Docker container matching CI.
#
# Usage:
#   scripts/linux-test.sh                          # clean build + test
#   scripts/linux-test.sh build                    # clean build only
#   scripts/linux-test.sh test                     # clean build + test
#   scripts/linux-test.sh test --filter OAuthTests # test with filter
#   scripts/linux-test.sh shell                    # open a shell in the container
#   scripts/linux-test.sh --incremental test       # reuse cached .build directory

set -euo pipefail

IMAGE="swift:6.2-noble"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VOLUME_NAME="swift-mcp-linux-build"
INCREMENTAL=false

usage() {
    cat <<'EOF'
Run Swift build and tests in a Linux Docker container matching CI.

Usage: scripts/linux-test.sh [options] [command] [swift flags...]

Commands:
  test       Build and run tests (default)
  build      Build only
  shell      Open a bash shell in the container

Options:
  --incremental   Reuse cached .build directory (default is clean build)
  -h, --help      Show this help message

Extra arguments are passed through to swift build/test:
  scripts/linux-test.sh test --filter OAuthTests
  scripts/linux-test.sh build --configuration release

Requires Docker to be installed and running.
EOF
}

# Parse flags
while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help) usage; exit 0 ;;
        --incremental) INCREMENTAL=true; shift ;;
        *) break ;;
    esac
done

MODE="${1:-test}"
shift || true  # consume the mode argument; remaining args are passed through

if ! command -v docker > /dev/null 2>&1; then
    echo "Error: Docker is not installed." >&2
    exit 1
fi

if ! docker info > /dev/null 2>&1; then
    echo "Error: Docker is not running." >&2
    exit 1
fi

# Pull the image if not already present
if ! docker image inspect "$IMAGE" > /dev/null 2>&1; then
    echo "Pulling $IMAGE..."
    docker pull "$IMAGE"
fi

# Clean builds delete the volume first to match CI behavior
if [ "$INCREMENTAL" = false ] && [ "$MODE" != "shell" ]; then
    docker volume rm "$VOLUME_NAME" > /dev/null 2>&1 || true
fi

DOCKER_ARGS=(
    --rm
    -v "$REPO_ROOT":/workspace
    -v "$VOLUME_NAME":/workspace/.build
    -w /workspace
    "$IMAGE"
)

# Install system dependencies that tests require (e.g., curl for HTTP integration tests)
SETUP="apt-get update -qq && apt-get install -yqq curl > /dev/null 2>&1"

case "$MODE" in
    build)
        docker run "${DOCKER_ARGS[@]}" bash -c "$SETUP && swift build $*"
        ;;
    test)
        docker run "${DOCKER_ARGS[@]}" bash -c "$SETUP && swift test $*"
        ;;
    shell)
        docker run -it "${DOCKER_ARGS[@]}" bash -c "$SETUP && exec bash"
        ;;
    *)
        usage
        exit 1
        ;;
esac
