# 🐳 Docker Auto Installer

Production-ready Docker installer for **Ubuntu and Debian** systems.

The installer automatically detects the Linux distribution and configures the appropriate official Docker repository.

## 📦 What It Installs

The script installs:

* Docker Engine
* Docker CLI
* Docker Compose Plugin
* Docker Buildx Plugin
* Containerd

It also:

* Detects Ubuntu or Debian automatically
* Removes conflicting/old Docker packages
* Configures the official Docker APT repository
* Installs and configures the Docker GPG key
* Enables and starts the Docker service
* Adds the current user to the `docker` group
* Verifies the Docker service
* Verifies Docker and Docker Compose versions
* Runs a `hello-world` container test

---

## ⚙️ Supported Operating Systems

The installer currently supports:

### Ubuntu

* Ubuntu 22.04 LTS
* Ubuntu 24.04 LTS
* Other supported Ubuntu releases with a valid Docker repository codename

### Debian

* Debian 12 (Bookworm)
* Debian 13 (Trixie)
* Other supported Debian releases with a valid Docker repository codename

The script detects the operating system automatically using:

```bash
/etc/os-release
```

Unsupported distributions are rejected automatically.

---

## 🚀 Installation

### Option 1 — One-Line Install

Run the installer directly from GitHub:

```bash
curl -fsSL https://raw.githubusercontent.com/yekyawhan/wazuh/7ec439638595a7d4f26ce232dd142c36c7239348/docker/install-docker.sh | sudo bash
```

### Option 2 — Download and Run

Download the script:

```bash
wget https://raw.githubusercontent.com/yekyawhan/wazuh/7ec439638595a7d4f26ce232dd142c36c7239348/docker/install-docker.sh
```

Make it executable:

```bash
chmod +x install-docker.sh
```

Run the installer:

```bash
sudo ./install-docker.sh
```

---

## 🔍 OS Detection

The installer automatically detects the operating system.

For Ubuntu:

```text
[INFO] OS: Ubuntu 24.04.3 LTS
[INFO] ID: ubuntu
[INFO] Docker repository OS: ubuntu
```

For Debian:

```text
[INFO] OS: Debian GNU/Linux 12 (bookworm)
[INFO] ID: debian
[INFO] Docker repository OS: debian
```

The Docker repository is selected automatically based on the detected OS.

Ubuntu uses:

```text
https://download.docker.com/linux/ubuntu
```

Debian uses:

```text
https://download.docker.com/linux/debian
```

---

## 🔐 Docker Repository

The installer uses the official Docker repository instead of distribution-provided Docker packages.

The repository configuration is created under:

```text
/etc/apt/sources.list.d/docker.sources
```

The Docker GPG key is stored at:

```text
/etc/apt/keyrings/docker.asc
```

The repository architecture is detected automatically:

```bash
dpkg --print-architecture
```

---

## 👤 Docker Group

The installer automatically adds the detected user to the `docker` group.

Example:

```text
[SUCCESS] User added to docker group: username
```

After installation, log out and log back in.

Alternatively, apply the group membership immediately with:

```bash
newgrp docker
```

Then verify:

```bash
docker ps
```

You should be able to use Docker without `sudo`.

---

## ✅ Verify Installation

Check Docker:

```bash
docker --version
```

Check Docker Compose:

```bash
docker compose version
```

Check the Docker service:

```bash
systemctl status docker
```

Or:

```bash
systemctl is-active docker
```

Expected result:

```text
active
```

Check Docker information:

```bash
docker info
```

---

## 🧪 Docker Test

The installer automatically runs:

```bash
docker run --rm hello-world
```

If the test succeeds:

```text
[SUCCESS] Docker hello-world test passed
```

If the Docker service is running but the `hello-world` image cannot be pulled, the installer reports a warning instead of treating the entire installation as failed.

This can happen when the server has restricted Internet access or Docker Hub connectivity is unavailable.

---

## 🛠️ Useful Docker Commands

Check running containers:

```bash
docker ps
```

Check all containers:

```bash
docker ps -a
```

List images:

```bash
docker images
```

Check Docker information:

```bash
docker info
```

Check Docker service:

```bash
systemctl status docker
```

Restart Docker:

```bash
sudo systemctl restart docker
```

Enable Docker at boot:

```bash
sudo systemctl enable docker
```

---

## 🐳 Docker Compose

Check Compose:

```bash
docker compose version
```

Start a Compose application:

```bash
docker compose up -d
```

Stop a Compose application:

```bash
docker compose down
```

View Compose logs:

```bash
docker compose logs -f
```

List Compose services:

```bash
docker compose ps
```

---

## 🔧 Troubleshooting

### Docker service is not running

Check the service:

```bash
sudo systemctl status docker --no-pager -l
```

Check recent logs:

```bash
sudo journalctl -u docker -n 100 --no-pager
```

Restart Docker:

```bash
sudo systemctl restart docker
```

### Permission denied when running Docker

If you see:

```text
permission denied while trying to connect to the Docker daemon socket
```

Check your groups:

```bash
groups
```

Add your user manually if required:

```bash
sudo usermod -aG docker "$USER"
```

Then log out and log back in, or run:

```bash
newgrp docker
```

Test:

```bash
docker ps
```

### Docker repository problems

Check the repository:

```bash
cat /etc/apt/sources.list.d/docker.sources
```

Check the GPG key:

```bash
ls -l /etc/apt/keyrings/docker.asc
```

Update APT:

```bash
sudo apt-get update
```

---

## 📁 Installation Files

The installer creates/configures:

```text
/etc/apt/keyrings/docker.asc
/etc/apt/sources.list.d/docker.sources
```

Docker data is normally stored under:

```text
/var/lib/docker
```

Containerd data is normally stored under:

```text
/var/lib/containerd
```

---

## 🔒 Security Notes

This installer uses:

* Official Docker APT repositories
* Docker's GPG signing key
* APT repository signature verification
* Architecture-specific repository configuration
* `set -euo pipefail` for safer script execution

The installer does not configure Docker's remote API.

Docker should normally remain accessible through the local Unix socket:

```text
/var/run/docker.sock
```

Do not expose the Docker daemon directly to the Internet unless you have a specific security architecture for doing so.

---

## 📌 Repository

Project repository:

```text
https://github.com/yekyawhan/wazuh
```

Installer location:

```text
docker/install-docker.sh
```

---

## 📄 License

This project is provided for infrastructure and system administration use.
