#!/bin/bash

set -euo pipefail

clear

echo "=========================================="
echo "      DOCKER INSTALLER (PRODUCTION)"
echo "=========================================="
echo ""

# -----------------------------------
# Require root
# -----------------------------------
if [ "$EUID" -ne 0 ]; then
    echo "[ERROR] Run as root or sudo"
    exit 1
fi

# -----------------------------------
# Detect OS
# -----------------------------------
if [ ! -f /etc/os-release ]; then
    echo "[ERROR] Unsupported Linux distribution"
    exit 1
fi

source /etc/os-release

OS_ID="${ID:-}"
OS_CODENAME="${VERSION_CODENAME:-}"

echo "[INFO] OS: ${PRETTY_NAME:-Unknown}"
echo "[INFO] ID: ${OS_ID}"
echo "[INFO] Codename: ${OS_CODENAME:-Unknown}"
echo ""

# -----------------------------------
# Detect supported distribution
# -----------------------------------
case "$OS_ID" in

    ubuntu)
        DOCKER_OS="ubuntu"

        # Ubuntu derivatives may expose UBUNTU_CODENAME
        if [ -n "${UBUNTU_CODENAME:-}" ]; then
            DOCKER_CODENAME="$UBUNTU_CODENAME"
        else
            DOCKER_CODENAME="$OS_CODENAME"
        fi

        ;;

    debian)
        DOCKER_OS="debian"
        DOCKER_CODENAME="$OS_CODENAME"

        ;;

    *)
        echo "[ERROR] Unsupported Linux distribution: $OS_ID"
        echo ""
        echo "Supported distributions:"
        echo "  - Ubuntu"
        echo "  - Debian"
        exit 1
        ;;
esac

# -----------------------------------
# Validate codename
# -----------------------------------
if [ -z "${DOCKER_CODENAME:-}" ]; then
    echo "[ERROR] Could not determine distribution codename"
    echo ""
    echo "OS: $OS_ID"
    echo "VERSION_CODENAME: ${VERSION_CODENAME:-not-set}"
    echo "UBUNTU_CODENAME: ${UBUNTU_CODENAME:-not-set}"
    exit 1
fi

echo "[INFO] Docker repository OS: $DOCKER_OS"
echo "[INFO] Docker repository codename: $DOCKER_CODENAME"
echo ""

# -----------------------------------
# Remove old Docker packages
# -----------------------------------
echo "[+] Removing old Docker packages..."

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
    apt-get remove -y "$pkg" >/dev/null 2>&1 || true
done

# -----------------------------------
# Install dependencies
# -----------------------------------
echo "[+] Installing dependencies..."

apt-get update -y

apt-get install -y \
    ca-certificates \
    curl \
    gnupg

# -----------------------------------
# Setup Docker GPG
# -----------------------------------
echo "[+] Setting up Docker GPG key..."

install -m 0755 -d /etc/apt/keyrings

DOCKER_GPG="/etc/apt/keyrings/docker.asc"

if [ ! -f "$DOCKER_GPG" ]; then

    curl -fsSL \
        "https://download.docker.com/linux/${DOCKER_OS}/gpg" \
        -o "$DOCKER_GPG"

else

    echo "[INFO] Docker GPG already exists, skipping..."

fi

chmod a+r "$DOCKER_GPG"

# -----------------------------------
# Setup Docker repository
# -----------------------------------
echo "[+] Adding Docker repository..."

ARCH=$(dpkg --print-architecture)

DOCKER_REPO="https://download.docker.com/linux/${DOCKER_OS}"

cat > /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: ${DOCKER_REPO}
Suites: ${DOCKER_CODENAME}
Components: stable
Architectures: ${ARCH}
Signed-By: ${DOCKER_GPG}
EOF

echo "[INFO] Docker repository:"
echo "       ${DOCKER_REPO}"
echo "[INFO] Architecture:"
echo "       ${ARCH}"
echo "[INFO] Suite:"
echo "       ${DOCKER_CODENAME}"
echo ""

# -----------------------------------
# Install Docker
# -----------------------------------
echo "[+] Installing Docker Engine..."

apt-get update -y

apt-get install -y \
    docker-ce \
    docker-ce-cli \
    containerd.io \
    docker-buildx-plugin \
    docker-compose-plugin

# -----------------------------------
# Add user to docker group
# -----------------------------------
echo ""
echo "[+] Configuring Docker permissions..."

REAL_USER="${SUDO_USER:-${USER:-root}}"

if id "$REAL_USER" &>/dev/null; then

    usermod -aG docker "$REAL_USER"

    echo "[SUCCESS] User added to docker group: $REAL_USER"
    echo ""
    echo "[IMPORTANT] Logout/login OR run:"
    echo "newgrp docker"

else

    echo "[WARNING] Could not determine real user"

fi

# -----------------------------------
# Enable/start Docker service
# -----------------------------------
echo ""
echo "[+] Starting Docker..."

systemctl daemon-reload
systemctl enable docker --now
systemctl restart docker

sleep 3

# -----------------------------------
# Verify Docker service
# -----------------------------------
echo ""
echo "[+] Checking Docker service..."

if systemctl is-active --quiet docker; then

    echo "[SUCCESS] Docker service is running"

else

    echo "[ERROR] Docker service failed"
    echo ""
    systemctl status docker --no-pager -l
    exit 1

fi

# -----------------------------------
# Verify Docker installation
# -----------------------------------
echo ""
echo "[+] Checking Docker version..."

docker --version
docker compose version

# -----------------------------------
# Docker information
# -----------------------------------
echo ""
echo "[+] Docker system information..."

docker info >/dev/null 2>&1 || true

# -----------------------------------
# Hello World test
# -----------------------------------
echo ""
echo "[+] Running hello-world test..."

if docker run --rm hello-world >/dev/null 2>&1; then

    echo "[SUCCESS] Docker hello-world test passed"

else

    echo "[WARNING] hello-world test failed"
    echo "[INFO] Docker service is running, but image test could not complete"

fi

# -----------------------------------
# Final output
# -----------------------------------
echo ""
echo "=========================================="
echo "[DONE] Docker installed successfully"
echo "=========================================="

echo ""
echo "System:"
echo "  OS           : ${PRETTY_NAME:-Unknown}"
echo "  Docker Repo  : ${DOCKER_OS}"
echo "  Codename     : ${DOCKER_CODENAME}"
echo "  Architecture : ${ARCH}"

echo ""
echo "Docker Version:"
docker --version

echo ""
echo "Docker Compose:"
docker compose version

echo ""
echo "Docker Service:"
systemctl is-active docker

echo ""
echo "Useful commands:"
echo "  docker ps"
echo "  docker images"
echo "  docker compose up -d"
echo "  docker compose down"
echo "  docker info"

echo ""
echo "=========================================="
