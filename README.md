# NMS Native (No Docker) — Ubuntu Installer + systemd

This repository provides a **single installer script** that sets up the NMS stack **natively** on Ubuntu 24.04 (no Docker):
- Postgres (native package)
- Caddy (TLS reverse proxy)
- FastAPI API service (systemd)
- Worker services (systemd)
- One config file in `/etc/nms/config.yaml`
- Journald logs

## Quick start (Ubuntu 24.04)
1) Create a fresh Ubuntu 24.04 VM.
2) Copy this repo to the VM (or `git clone` it).
3) Run:

```bash
cd nms-native
chmod +x packaging/install_nms.sh
sudo REPO_URL="https://github.com/YOURORG/YOUR-NMS-CODE-REPO.git" \
  API_APP_IMPORT="yourpkg.api.main:app" \
  WORKER_MODULE="yourpkg.worker.main" \
  MIGRATE_CMD="python -m yourpkg.db migrate" \
  ENSURE_ADMIN_CMD="python -m yourpkg.users ensure-admin --username admin --password __PASS__ --role admin" \
  ./packaging/install_nms.sh
```

> If your NMS code is already present at `/opt/nms/app`, omit `REPO_URL`.

## After install
- UI: `https://<vm-ip>/`
- Initial credentials: `/etc/nms/initial-credentials.txt`
- Logs:
  - `journalctl -u nms-api -f`
  - `journalctl -u nms-worker@poller -f`

## Notes
- This repo is the **installer/packaging**. Your actual NMS Python code lives in a separate repo referenced by `REPO_URL`.
- The installer is intentionally strict about required env vars so it doesn't guess your module paths.
