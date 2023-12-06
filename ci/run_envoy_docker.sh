#!/bin/bash

set -e

# shellcheck source=ci/envoy_build_sha.sh
. "$(dirname "$0")"/envoy_build_sha.sh

function is_windows() {
  [[ "$(uname -s)" == *NT* ]]
}

read -ra ENVOY_DOCKER_OPTIONS <<< "${ENVOY_DOCKER_OPTIONS:-}"

# TODO(phlax): uppercase these env vars
export HTTP_PROXY="${http_proxy:-}"
export HTTPS_PROXY="${https_proxy:-}"
export NO_PROXY="${no_proxy:-}"
export GOPROXY="${go_proxy:-}"

# This is what the original assumes gets mounted
DOCKER_HOST="${DOCKER_HOST:-unix:///var/run/docker.sock}"
ENVOY_DOCKER_SOCKET="${ENVOY_DOCKER_SOCKET:-"${DOCKER_HOST#unix://}"}"

if is_windows; then
  [[ -z "${IMAGE_NAME}" ]] && IMAGE_NAME="envoyproxy/envoy-build-windows2019"
  # TODO(sunjayBhatia): Currently ENVOY_DOCKER_OPTIONS is ignored on Windows because
  # CI sets it to a Linux-specific value. Undo this once https://github.com/envoyproxy/envoy/issues/13272
  # is resolved.
  ENVOY_DOCKER_OPTIONS=()
  # Replace MSYS style drive letter (/c/) with Windows drive letter designation (C:/)
  DEFAULT_ENVOY_DOCKER_BUILD_DIR=$(echo "${TEMP}" | sed -E "s#^/([a-zA-Z])/#\1:/#")/envoy-docker-build
  BUILD_DIR_MOUNT_DEST=C:/build
  SOURCE_DIR=$(echo "${PWD}" | sed -E "s#^/([a-zA-Z])/#\1:/#")
  SOURCE_DIR_MOUNT_DEST=C:/source
  START_COMMAND=("bash" "-c" "cd /c/source && export HOME=/c/build && $*")
else
  [[ -z "${IMAGE_NAME}" ]] && IMAGE_NAME="envoyproxy/envoy-build-ubuntu"
  # We run as root and later drop permissions. This is required to setup the USER
  # in useradd below, which is need for correct Python execution in the Docker
  # environment.
  # NOTE(jjwatt): Podman handles this fine running rootless in userns as root.
  # You should not need `--privledged`, either! If you need to give access to
  # the user podman socket, start up the systemd user service, 'podman.socket',
  # and you should get a $XDG_RUNTIME_DIR/podman/podman.sock.
  # Set DOCKER_HOST to the podman sock, $XDG_RUNTIME_DIR/podman/podman.sock.
  ENVOY_DOCKER_OPTIONS+=(-u root:root)
  # ENVOY_DOCKER_OPTIONS+=(-v /var/run/docker.sock:/var/run/docker.sock)
  ENVOY_DOCKER_OPTIONS+=(-v "${ENVOY_DOCKER_SOCKET}:${ENVOY_DOCKER_SOCKET}")
  ENVOY_DOCKER_OPTIONS+=(--cap-add SYS_PTRACE --cap-add NET_RAW --cap-add NET_ADMIN)
  DEFAULT_ENVOY_DOCKER_BUILD_DIR=/tmp/envoy-docker-build
  BUILD_DIR_MOUNT_DEST=/build
  SOURCE_DIR="${PWD}"
  SOURCE_DIR_MOUNT_DEST=/source
  # TODO(jjwatt): Only do this uid injection bullshit on docker. podman is ill enough to handle it, baby.
  # Actually, it doesn't seem like anything refers to the envoybuild user or group anywhere else.
  # We can probably just unit it out for podman.
  # This is trash.
  # This relies on START_COMMAND expanding id -g, etc on your host.
  # cd can fail :'(
  START_COMMAND=("/bin/bash" "-lc" "groupadd --gid $(id -g) -f envoygroup \
    && useradd -o --uid $(id -u) --gid $(id -g) --no-create-home --home-dir /build envoybuild \
    && usermod -a -G pcap envoybuild \
    && chown envoybuild:envoygroup /build \
    && sudo -EHs -u envoybuild bash -c 'cd /source && $*'")
  # TODO(jjwatt): I'm not sure what putting us in the pcap group is for, but it *could* be why some tests
  # seem to be failing in my build. Even though it runs as root, if the tests need that capability,
  # then I probably need to add it as a cap the right way (instead of wtf they're doing here).
  if [[ -n $JWTESTING ]]; then
      export START_COMMAND=("/bin/bash" "-c" "cd /source && $*")
  fi
fi

# The IMAGE_ID defaults to the CI hash but can be set to an arbitrary image ID (found with 'docker
# images').
[[ -z "${IMAGE_ID}" ]] && IMAGE_ID="${ENVOY_BUILD_SHA}"
[[ -z "${ENVOY_DOCKER_BUILD_DIR}" ]] && ENVOY_DOCKER_BUILD_DIR="${DEFAULT_ENVOY_DOCKER_BUILD_DIR}"
# Replace backslash with forward slash for Windows style paths
ENVOY_DOCKER_BUILD_DIR="${ENVOY_DOCKER_BUILD_DIR//\\//}"
mkdir -p "${ENVOY_DOCKER_BUILD_DIR}"

[[ -t 1 ]] && ENVOY_DOCKER_OPTIONS+=("-it")
[[ -f .git ]] && [[ ! -d .git ]] && ENVOY_DOCKER_OPTIONS+=(-v "$(git rev-parse --git-common-dir):$(git rev-parse --git-common-dir)")
[[ -n "${SSH_AUTH_SOCK}" ]] && ENVOY_DOCKER_OPTIONS+=(-v "${SSH_AUTH_SOCK}:${SSH_AUTH_SOCK}" -e SSH_AUTH_SOCK)

export ENVOY_BUILD_IMAGE="${IMAGE_NAME}:${IMAGE_ID}"

VOLUMES=(
    -v "${ENVOY_DOCKER_BUILD_DIR}":"${BUILD_DIR_MOUNT_DEST}:Z"
    -v "${SOURCE_DIR}":"${SOURCE_DIR_MOUNT_DEST}:Z")

if ! is_windows; then
    # Create a "shared" directory that has the same path in/outside the container
    # This allows the host docker engine to see artefacts using a temporary path created inside the container,
    # at the same path.
    # For example, a directory created with `mktemp -d --tmpdir /tmp/bazel-shared` can be mounted as a volume
    # from within the build container.
    SHARED_TMP_DIR=/tmp/bazel-shared
    mkdir -p "${SHARED_TMP_DIR}"
    chmod +rwx "${SHARED_TMP_DIR}"
    VOLUMES+=(-v "${SHARED_TMP_DIR}":"${SHARED_TMP_DIR}:Z")
fi

time docker pull "${ENVOY_BUILD_IMAGE}"


# Since we specify an explicit hash, docker-run will pull from the remote repo if missing.
echo "DEBUG: Volumes:"
echo "${VOLUMES[@]}"
docker run --rm \
       "${ENVOY_DOCKER_OPTIONS[@]}" \
       "${VOLUMES[@]}" \
       -e AZP_BRANCH \
       -e HTTP_PROXY \
       -e HTTPS_PROXY \
       -e NO_PROXY \
       -e GOPROXY \
       -e BAZEL_STARTUP_OPTIONS \
       -e BAZEL_BUILD_EXTRA_OPTIONS \
       -e BAZEL_EXTRA_TEST_OPTIONS \
       -e BAZEL_REMOTE_CACHE \
       -e ENVOY_STDLIB \
       -e BUILD_REASON \
       -e BAZEL_REMOTE_INSTANCE \
       -e GOOGLE_BES_PROJECT_ID \
       -e GCP_SERVICE_ACCOUNT_KEY \
       -e NUM_CPUS \
       -e ENVOY_RBE \
       -e ENVOY_BUILD_IMAGE \
       -e ENVOY_SRCDIR \
       -e ENVOY_BUILD_TARGET \
       -e ENVOY_BUILD_DEBUG_INFORMATION \
       -e SYSTEM_PULLREQUEST_PULLREQUESTNUMBER \
       -e GCS_ARTIFACT_BUCKET \
       -e GITHUB_TOKEN \
       -e BUILD_SOURCEBRANCHNAME \
       -e BAZELISK_BASE_URL \
       -e ENVOY_BUILD_ARCH \
       -e SLACK_TOKEN \
       -e BUILD_URI\
       -e REPO_URI \
       -e SYSTEM_STAGEDISPLAYNAME \
       -e SYSTEM_JOBDISPLAYNAME \
       -e SYSTEM_PULLREQUEST_PULLREQUESTNUMBER \
       "${ENVOY_BUILD_IMAGE}" \
       "${START_COMMAND[@]}"
