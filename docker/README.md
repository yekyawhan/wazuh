# 🐳 Docker Auto Installer

A Bash installer for Docker Engine on supported Ubuntu and Debian systems. It detects the distribution, configures Docker's official APT repository, installs Docker Engine and the Compose/Buildx plugins, and verifies that the daemon is responding.

## What it installs

- Docker Engine (`docker-ce`)
- Docker CLI (`docker-ce-cli`)
- Containerd (`containerd.io`)
- Docker Buildx Plugin
- Docker Compose Plugin

The script also refreshes Docker's GPG key, removes stale repository definitions created by earlier versions of this installer, checks that the selected Docker repository release exists, detects whether Docker packages are available for the host, and checks service readiness.

## Supported operating systems

The script recognizes the following distribution IDs:

- Ubuntu
- Debian

A valid codename alone does not guarantee that Docker publishes packages for a release or architecture. The installer checks Docker's repository metadata and the APT package candidate before removing conflicting distribution packages or installing Docker.

Refer to the official documentation for current support and architecture details:

- [Docker Engine on Ubuntu](https://docs.docker.com/engine/install/ubuntu/)
- [Docker Engine on Debian](https://docs.docker.com/engine/install/debian/)

## Installation

### Option 1 — Download, inspect, and run (recommended)

```bash
wget -O install-docker.sh https://raw.githubusercontent.com/yekyawhan/wazuh/89cf37f1e95952ce3d87883e5b65ef4259a4d962/docker/install-docker.sh
sed -n '1,340p' install-docker.sh
chmod +x install-docker.sh
sudo ./install-docker.sh
```

### Option 2 — Run directly from GitHub

Use this only after reviewing the script at the linked repository revision.

```bash
curl -fsSL https://raw.githubusercontent.com/yekyawhan/wazuh/89cf37f1e95952ce3d87883e5b65ef4259a4d962/docker/install-docker.sh | sudo bash
```

## Safety and operational notes

- Run as root or with `sudo`.
- The script removes stale Docker APT source files at `/etc/apt/sources.list.d/docker.list` and `/etc/apt/sources.list.d/docker.sources`, then writes the correct distribution-specific `docker.sources` file.
- It checks for Docker repository release metadata and an available `docker-ce` package before removing conflicting distribution packages.
- It may remove conflicting distribution-provided packages, including `docker.io`, `containerd`, and `runc`. Existing containers managed by those packages may be stopped during migration. Review the impact before running on a host with production containers or Kubernetes/containerd workloads.
- The script does **not** delete `/var/lib/docker` or `/var/lib/containerd`, and it does not run `apt autoremove`.
- It does not explicitly restart the Docker service after enabling it, avoiding an unnecessary restart if the service is already running. Package upgrades themselves may still restart services.
- If run through `sudo`, it attempts to add the invoking non-root user to the `docker` group. If run directly as root, it skips guessing which user should receive access.
- Membership in the `docker` group grants root-equivalent privileges. Add only trusted users.
- The daemon must become responsive within 30 seconds. The `hello-world` connectivity test is limited to 120 seconds; if it fails, the script reports a warning separately from the service-readiness check.
- Docker-published container ports can interact with host firewall rules. Review Docker's [packet filtering and firewalls guidance](https://docs.docker.com/engine/network/packet-filtering-firewalls/) before exposing services.

## Verify the installation

```bash
docker --version
docker compose version
systemctl is-active docker
docker info
docker ps
```

The Docker service should report `active`. After the script adds a user to the `docker` group, log out and log back in (or start a new group session) before running Docker as that user.

## Useful commands

```bash
docker ps
docker ps -a
docker images
docker compose up -d
docker compose logs -f
docker compose down
sudo systemctl status docker --no-pager -l
sudo journalctl -u docker -n 100 --no-pager
```

## Files configured

- `/etc/apt/keyrings/docker.asc`
- `/etc/apt/sources.list.d/docker.sources`

## Repository

- Project: https://github.com/yekyawhan/wazuh
- Installer: `docker/install-docker.sh`
- Documentation: `docker/README.md`
