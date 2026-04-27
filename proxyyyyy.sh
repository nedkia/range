#!/usr/bin/env bash
# Adds corporate proxy settings throughout the repo.
# Usage: ./add-proxy.sh [PROXY_URL]
# Default proxy: http://foo.bar:3128

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

PROXY_URL="${1:-http://foo.bar:3128}"
NO_PROXY="localhost,127.0.0.1"

echo "==> Adding proxy settings for ${PROXY_URL}..."

PROXY_URL="$PROXY_URL" NO_PROXY="$NO_PROXY" python3 - <<'PY'
import os, re
from pathlib import Path

PROXY_URL = os.environ["PROXY_URL"]
NO_PROXY  = os.environ["NO_PROXY"]

# ── docker-compose.yml: build args for ranger ─────────────────────────────────
p = Path("docker-compose.yml")
t = p.read_text()

if "HTTP_PROXY" not in t:
    t = t.replace(
        "      dockerfile: Dockerfile\n    env_file:",
        f"      dockerfile: Dockerfile\n      args:\n"
        f"        HTTP_PROXY: {PROXY_URL}\n"
        f"        HTTPS_PROXY: {PROXY_URL}\n"
        f"        NO_PROXY: {NO_PROXY}\n"
        f"    env_file:",
    )
    p.write_text(t)
    print("    docker-compose.yml updated.")
else:
    print("    docker-compose.yml: proxy args already present, skipped.")

# ── ranger-api/Dockerfile ─────────────────────────────────────────────────────
p = Path("ranger-api/Dockerfile")
t = p.read_text()

if "ARG HTTP_PROXY" not in t:
    t = t.replace(
        "ARG TARGETARCH\n",
        "ARG TARGETARCH\nARG HTTP_PROXY\nARG HTTPS_PROXY\nARG NO_PROXY\n",
    )
    p.write_text(t)
    print("    ranger-api/Dockerfile updated.")
else:
    print("    ranger-api/Dockerfile: proxy ARGs already present, skipped.")

# ── integrations/ghosts/ghosts-mcp/Dockerfile ─────────────────────────────────
p = Path("integrations/ghosts/ghosts-mcp/Dockerfile")
t = p.read_text()

if "ARG HTTP_PROXY" not in t:
    t = t.replace(
        "FROM python:3.11-slim\n",
        "FROM python:3.11-slim\n\nARG HTTP_PROXY\nARG HTTPS_PROXY\nARG NO_PROXY\n",
    )
    p.write_text(t)
    print("    integrations/ghosts/ghosts-mcp/Dockerfile updated.")
else:
    print("    integrations/ghosts/ghosts-mcp/Dockerfile: proxy ARGs already present, skipped.")

# ── ranger-appliance/setup-appliance.sh ───────────────────────────────────────
p = Path("ranger-appliance/setup-appliance.sh")
t = p.read_text()

if "PROXY_URL=" not in t:
    proxy_block = (
        f'# Proxy configuration\n'
        f'PROXY_URL="{PROXY_URL}"\n'
        f'export http_proxy="${{PROXY_URL}}"\n'
        f'export https_proxy="${{PROXY_URL}}"\n'
        f'export HTTP_PROXY="${{PROXY_URL}}"\n'
        f'export HTTPS_PROXY="${{PROXY_URL}}"\n'
        f'export no_proxy="{NO_PROXY}"\n'
        f'\n'
        f'# Configure apt proxy so sudo apt-get picks it up\n'
        f'echo "Acquire::http::Proxy \\"${{PROXY_URL}}\\";" | sudo tee /etc/apt/apt.conf.d/01proxy > /dev/null\n'
        f'echo "Acquire::https::Proxy \\"${{PROXY_URL}}\\";" | sudo tee -a /etc/apt/apt.conf.d/01proxy > /dev/null\n'
        f'\n'
    )
    t = t.replace("set -euo pipefail\n\n", f"set -euo pipefail\n\n{proxy_block}")
    p.write_text(t)
    print("    ranger-appliance/setup-appliance.sh: proxy env block added.")
else:
    print("    ranger-appliance/setup-appliance.sh: proxy block already present, skipped.")

# Add -x flag to the docker GPG curl if missing
t = p.read_text()
if '-x "${PROXY_URL}"' not in t:
    t = t.replace(
        "sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg",
        'sudo curl -fsSL -x "${PROXY_URL}" https://download.docker.com/linux/ubuntu/gpg',
    )
    p.write_text(t)
    print("    ranger-appliance/setup-appliance.sh: curl proxy flag added.")

# Add Docker daemon proxy block before the final docker compose up
t = p.read_text()
if "DOCKER_PROXY_EOF" not in t:
    docker_proxy_block = (
        f'# Configure Docker daemon proxy so it can pull images through the proxy\n'
        f'sudo mkdir -p /etc/systemd/system/docker.service.d\n'
        f"sudo tee /etc/systemd/system/docker.service.d/http-proxy.conf > /dev/null <<'DOCKER_PROXY_EOF'\n"
        f'[Service]\n'
        f'Environment="HTTP_PROXY={PROXY_URL}"\n'
        f'Environment="HTTPS_PROXY={PROXY_URL}"\n'
        f'Environment="NO_PROXY={NO_PROXY}"\n'
        f'DOCKER_PROXY_EOF\n'
        f'sudo systemctl daemon-reload\n'
        f'sudo systemctl restart docker\n'
        f'\n'
    )
    t = t.replace(
        'echo "Starting docker compose..."\n',
        f'{docker_proxy_block}echo "Starting docker compose..."\n',
    )
    p.write_text(t)
    print("    ranger-appliance/setup-appliance.sh: Docker daemon proxy block added.")

print("Done.")
PY

echo "==> Proxy settings applied for ${PROXY_URL}."
echo "    Re-run 'docker compose build' to rebuild images with the proxy baked in."
