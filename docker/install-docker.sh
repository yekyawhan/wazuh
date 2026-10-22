#!/usr/bin/env bash

set -Eeuo pipefail

# Keep non-interactive use safe when TERM is unset.
if [[ -t 1 && -n "${TERM:-}" ]] && command -v clear >/dev/null 2>&1; then
    clear
fi

echo "=========================================="
echo "      DOCKER INSTALLER (UBUNTU/DEBIAN)"
echo "=========================================="
echo

# -----------------------------------
# Require root and required system tools
# -----------------------------------
if (( EUID != 0 )); then
    echo "[ERROR] Run as root or with sudo."
    exit 1
fi

for cmd in apt-get apt-cache dpkg dpkg-query systemctl; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "[ERROR] Required command not found: $cmd"
        exit 1
    fi
done

# -----------------------------------
# Detect supported OS
# -----------------------------------
if [[ ! -r /etc/os-release ]]; then
    echo "[ERROR] Cannot read /etc/os-release; unsupported Linux distribution."
    exit 1
fi

# shellcheck source=/etc/os-release
source /etc/os-release

OS_ID="${ID:-}"
OS_CODENAME="${VERSION_CODENAME:-}"
DOCKER_OS=""
DOCKER_CODENAME=""

case "$OS_ID" in
    ubuntu)
        DOCKER_OS="ubuntu"
        DOCKER_CODENAME="${UBUNTU_CODENAME:-$OS_CODENAME}"
        ;;
    debian)
        DOCKER_OS="debian"
        DOCKER_CODENAME="$OS_CODENAME"
        ;;
    *)
        echo "[ERROR] Unsupported Linux distribution: ${OS_ID:-unknown}"
        echo "[INFO] Supported distribution IDs: ubuntu, debian"
        exit 1
        ;;
esac

if [[ -z "$DOCKER_CODENAME" ]]; then
    echo "[ERROR] Could not determine the OS release codename."
    echo "[INFO] VERSION_CODENAME=${VERSION_CODENAME:-not-set}"
    echo "[INFO] UBUNTU_CODENAME=${UBUNTU_CODENAME:-not-set}"
    exit 1
fi

ARCH="$(dpkg --print-architecture)"
if [[ -z "$ARCH" ]]; then
    echo "[ERROR] Could not determine package architecture."
    exit 1
fi

DOCKER_REPO="https://download.docker.com/linux/${DOCKER_OS}"
DOCKER_GPG="/etc/apt/keyrings/docker.asc"
DOCKER_SOURCE_FILE="/etc/apt/sources.list.d/docker.sources"

printf '[INFO] OS: %s\n' "${PRETTY_NAME:-Unknown}"
printf '[INFO] ID: %s\n' "$OS_ID"
printf '[INFO] Codename: %s\n' "$DOCKER_CODENAME"
printf '[INFO] Docker repository: %s\n' "$DOCKER_REPO"
printf '[INFO] Architecture: %s\n\n' "$ARCH"

echo "[WARNING] This script may remove conflicting distribution-provided Docker/containerd packages."
echo "[WARNING] Existing containers managed by those packages may be stopped during migration."
echo "[INFO] Docker data directories are not deleted by this script."
echo

# -----------------------------------
# Remove stale repository definitions from previous installer versions
# -----------------------------------
# The previous script version could leave Ubuntu's repository configured on Debian.
echo "[+] Removing stale Docker repository configuration..."
rm -f /etc/apt/sources.list.d/docker.list "$DOCKER_SOURCE_FILE"

# -----------------------------------
# Install prerequisites
# -----------------------------------
echo "[+] Updating APT package lists..."
apt-get update

echo "[+] Installing required dependencies..."
DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl gnupg

# Validate the suite before writing a new APT source file. This prevents an
# unsupported codename from leaving a broken Docker repository configured.
echo "[+] Checking Docker repository release metadata..."
if ! curl --fail --silent --show-error --location \
    --connect-timeout 10 --max-time 30 --retry 2 \
    --output /dev/null \
    "${DOCKER_REPO}/dists/${DOCKER_CODENAME}/Release"; then
    echo "[ERROR] Docker repository metadata is unavailable for ${DOCKER_OS}/${DOCKER_CODENAME}."
    echo "[INFO] The release may be unsupported, or this server may not be able to reach download.docker.com."
    echo "[INFO] No new Docker APT source file has been written."
    exit 1
fi

# -----------------------------------
# Set up Docker GPG key (refresh on every run)
# -----------------------------------
echo "[+] Downloading Docker GPG key..."
install -m 0755 -d /etc/apt/keyrings
key_tmp="$(mktemp /etc/apt/keyrings/docker.asc.XXXXXX)"
if ! curl -fsSL "${DOCKER_REPO}/gpg" -o "$key_tmp"; then
    rm -f "$key_tmp"
    echo "[ERROR] Failed to download Docker's GPG key from ${DOCKER_REPO}/gpg"
    exit 1
fi
chmod 0644 "$key_tmp"
mv -f "$key_tmp" "$DOCKER_GPG"

# -----------------------------------
# Configure Docker's official repository atomically
# -----------------------------------
echo "[+] Configuring Docker APT repository..."
install -m 0755 -d /etc/apt/sources.list.d
source_tmp="$(mktemp /etc/apt/sources.list.d/docker.sources.XXXXXX)"
cat > "$source_tmp" <<EOF_REPO
Types: deb
URIs: ${DOCKER_REPO}
Suites: ${DOCKER_CODENAME}
Components: stable
Architectures: ${ARCH}
Signed-By: ${DOCKER_GPG}
EOF_REPO
chmod 0644 "$source_tmp"
mv -f "$source_tmp" "$DOCKER_SOURCE_FILE"

# -----------------------------------
# Update package lists and verify Docker packages are available
# -----------------------------------
echo "[+] Refreshing APT package lists with Docker repository..."
apt-get update

if ! DOCKER_POLICY="$(apt-cache policy docker-ce)"; then
    echo "[ERROR] Failed to query APT policy for docker-ce."
    exit 1
fi

# Do not use awk ... exit here: with set -o pipefail, an early-exiting reader
# can cause the producer to receive SIGPIPE and abort the installer.
DOCKER_CANDIDATE="$(printf '%s\n' "$DOCKER_POLICY" | sed -n 's/^[[:space:]]*Candidate:[[:space:]]*//p')"

if [[ -z "$DOCKER_CANDIDATE" || "$DOCKER_CANDIDATE" == "(none)" ]]; then
    echo "[ERROR] Docker Engine is not available for ${DOCKER_OS}/${DOCKER_CODENAME}/${ARCH}."
    echo "[INFO] APT policy output:"
    printf '%s\n' "$DOCKER_POLICY"
    echo "[INFO] Check Docker's supported OS releases and architectures:"
    echo "       https://docs.docker.com/engine/install/${DOCKER_OS}/"
    exit 1
fi
printf '[INFO] Docker Engine candidate: %s\n\n' "$DOCKER_CANDIDATE"

# -----------------------------------
# Remove conflicting distro packages, but only if installed
# This occurs only after repository metadata and package availability are valid.
# -----------------------------------
echo "[+] Checking for conflicting Docker packages..."
conflicting_packages=()
for pkg in \
    docker.io \
    docker-doc \
    docker-compose \
    docker-compose-v2 \
    docker-buildx \
    podman-docker \
    containerd \
    runc
do
    package_status="$(dpkg-query -W -f='${db:Status-Status}' "$pkg" 2>/dev/null || true)"
    if [[ "$package_status" == "installed" ]]; then
        conflicting_packages+=("$pkg")
    fi
done

if (( ${#conflicting_packages[@]} > 0 )); then
    printf '[INFO] Removing conflicting packages: %s\n' "${conflicting_packages[*]}"
    DEBIAN_FRONTEND=noninteractive apt-get remove -y "${conflicting_packages[@]}"
else
    echo "[INFO] No conflicting distribution packages found."
fi

# -----------------------------------
# Install Docker Engine and plugins
# -----------------------------------
echo "[+] Installing Docker Engine and plugins..."
DEBIAN_FRONTEND=noninteractive apt-get install -y \
    docker-ce \
    docker-ce-cli \
    containerd.io \
    docker-buildx-plugin \
    docker-compose-plugin

# -----------------------------------
# Add the invoking sudo user to docker group when identifiable
# -----------------------------------
echo
echo "[+] Configuring Docker permissions..."
REAL_USER="${SUDO_USER:-}"
if [[ -n "$REAL_USER" && "$REAL_USER" != "root" ]] && id "$REAL_USER" >/dev/null 2>&1; then
    if ! getent group docker >/dev/null 2>&1; then
        echo "[ERROR] Docker group does not exist after package installation."
        exit 1
    fi
    usermod -aG docker "$REAL_USER"
    echo "[SUCCESS] Added user to docker group: $REAL_USER"
    echo "[IMPORTANT] Log out and log back in for group membership to take effect, or run: newgrp docker"
    echo "[SECURITY] Membership in the docker group grants root-equivalent privileges."
else
    echo "[INFO] No non-root SUDO_USER was detected; skipping automatic docker-group changes."
    echo "[INFO] Root can administer Docker directly. Add a trusted user manually if required."
fi

# -----------------------------------
# Enable/start Docker without an unnecessary explicit restart
# -----------------------------------
echo
echo "[+] Enabling and starting Docker..."
systemctl enable --now docker

# -----------------------------------
# Wait for Docker daemon readiness
# -----------------------------------
echo "[+] Waiting for Docker daemon..."
docker_ready=0
for attempt in {1..30}; do
    if docker info >/dev/null 2>&1; then
        docker_ready=1
        break
    fi
    sleep 1
done

if (( docker_ready == 0 )); then
    echo "[ERROR] Docker service did not become ready within 30 seconds."
    systemctl status docker --no-pager -l || true
    journalctl -u docker -n 80 --no-pager || true
    exit 1
fi

echo "[SUCCESS] Docker daemon is responding."

# -----------------------------------
# Verify installed versions
# -----------------------------------
echo
echo "[+] Verifying Docker versions..."
docker --version
docker compose version

# -----------------------------------
# Run a bounded hello-world test
# -----------------------------------
echo
echo "[+] Running hello-world test (maximum 120 seconds)..."
if command -v timeout >/dev/null 2>&1; then
    if timeout 120 docker run --rm hello-world; then
        HELLO_WORLD_OK=1
    else
        HELLO_WORLD_OK=0
    fi
else
    if docker run --rm hello-world; then
        HELLO_WORLD_OK=1
    else
        HELLO_WORLD_OK=0
    fi
fi

# -----------------------------------
# Final summary
# -----------------------------------
echo
echo "=========================================="
if (( HELLO_WORLD_OK == 1 )); then
    echo "[DONE] Docker installed and verified successfully"
else
    echo "[DONE] Docker Engine is installed and running; hello-world test did not complete."
    echo "[WARNING] Check Docker Hub connectivity and daemon logs if the test failed."
fi
echo "=========================================="
echo
echo "System:"
printf '  OS           : %s\n' "${PRETTY_NAME:-Unknown}"
printf '  Docker Repo  : %s\n' "$DOCKER_REPO"
printf '  Codename     : %s\n' "$DOCKER_CODENAME"
printf '  Architecture : %s\n' "$ARCH"
echo
echo "Docker Version:"
docker --version
echo
echo "Docker Compose:"
docker compose version
echo
echo "Docker Service:"
systemctl is-active docker
echo
echo "Useful commands:"
echo "  docker ps"
echo "  docker images"
echo "  docker compose up -d"
echo "  docker compose down"
echo "  docker info"
echo
echo "=========================================="
