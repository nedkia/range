#!/usr/bin/env bash
# Idempotent first-run setup for Ranger.
# Run from the repo root. Requires: docker, python3, sudo (for Ollama config).

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

# ─── 1. Patch source files (idempotent) ─────────────────────────────────────
echo "==> Patching source files..."
python3 - <<'PY'
import re
from pathlib import Path

# ── docker-compose.yml ────────────────────────────────────────────────────────
p = Path("docker-compose.yml")
t = p.read_text()

# Remove proxy build-args block if present
t = re.sub(
    r'      args:\n        HTTP_PROXY:[^\n]*\n        HTTPS_PROXY:[^\n]*\n        NO_PROXY:[^\n]*\n',
    '',
    t,
)

# Add extra_hosts to ranger service if missing
if 'host.docker.internal:host-gateway' not in t:
    t = t.replace(
        '    ports:\n      - "5076:5000"\n    networks:',
        '    ports:\n      - "5076:5000"\n    extra_hosts:\n      - "host.docker.internal:host-gateway"\n    networks:',
    )

p.write_text(t)

# ── ranger-api/Dockerfile ─────────────────────────────────────────────────────
p = Path("ranger-api/Dockerfile")
t = p.read_text()
t = re.sub(r'ARG (?:HTTP_PROXY|HTTPS_PROXY|NO_PROXY)\n', '', t)
t = re.sub(r'\n{3,}', '\n\n', t)
p.write_text(t)

# ── integrations/ghosts/ghosts-mcp/Dockerfile ─────────────────────────────────
p = Path("integrations/ghosts/ghosts-mcp/Dockerfile")
t = p.read_text()
t = re.sub(r'ARG (?:HTTP_PROXY|HTTPS_PROXY|NO_PROXY)\n', '', t)
t = re.sub(r'\n{3,}', '\n\n', t)
p.write_text(t)

# ── ranger-appliance/setup-appliance.sh ───────────────────────────────────────
p = Path("ranger-appliance/setup-appliance.sh")
t = p.read_text()

# Remove proxy env-var export block + apt proxy config
t = re.sub(
    r'# Proxy configuration\nPROXY_URL=[^\n]+\n(?:export [^\n]+\n)+\n'
    r'# Configure apt proxy[^\n]*\n(?:[^\n]+\n)+\n',
    '',
    t,
)

# Remove -x "${PROXY_URL}" from curl
t = t.replace(' -x "${PROXY_URL}"', '')

# Remove Docker daemon proxy block + systemd reload/restart
t = re.sub(
    r'# Configure Docker daemon proxy[^\n]*\n'
    r'sudo mkdir -p[^\n]+\n'
    r"sudo tee[^\n]+<<'DOCKER_PROXY_EOF'\n"
    r'(?:[^\n]*\n)+'
    r'DOCKER_PROXY_EOF\n'
    r'sudo systemctl daemon-reload\n'
    r'sudo systemctl restart docker\n'
    r'\n',
    '',
    t,
)

p.write_text(t)
print("    Done.")
PY

# ─── 2. Ollama: bind on all interfaces ───────────────────────────────────────
echo "==> Configuring Ollama..."
sudo mkdir -p /etc/systemd/system/ollama.service.d
sudo tee /etc/systemd/system/ollama.service.d/override.conf > /dev/null <<'SYSD'
[Service]
Environment="OLLAMA_HOST=0.0.0.0"
SYSD
sudo systemctl daemon-reload
sudo systemctl restart ollama

echo -n "    Waiting for Ollama... "
until curl -sf http://localhost:11434/api/tags > /dev/null 2>&1; do sleep 1; done
echo "ready."

# ─── 3. .env ─────────────────────────────────────────────────────────────────
echo "==> Writing .env..."
if [[ ! -f .env ]]; then
    cat > .env <<'ENV'
# Ollama - running on the host, accessible from Docker containers via host.docker.internal
OLLAMA_HOST=http://host.docker.internal:11434

# n8n - reachable by container name since it's on the same Docker network (ranger-net)
N8N_API_URL=http://n8n:5678

# Generate this from the n8n UI: Settings > API > Create an API Key
N8N_API_KEY=

# GHOSTS NPC framework host (optional, only needed if using GHOSTS integration)
GHOSTS_HOST=http://host.docker.internal:5000
ENV
fi

# ─── 4. Start all services except ranger ─────────────────────────────────────
echo "==> Starting postgres, n8n, open-webui, qdrant, baserow..."
docker compose up -d postgres n8n open-webui qdrant baserow

echo -n "    Waiting for n8n... "
until curl -sf http://localhost:5678/healthz > /dev/null 2>&1; do sleep 2; done
echo "ready."

# ─── 5. n8n API key ───────────────────────────────────────────────────────────
if ! grep -qE 'N8N_API_KEY=.+' .env; then
    echo ""
    echo "    Open http://localhost:5678 → Settings → API → Create an API key."
    read -rp "    Paste key and press Enter: " n8n_key
    sed -i "s|N8N_API_KEY=.*|N8N_API_KEY=${n8n_key}|" .env
fi

# ─── 6. Start ranger ─────────────────────────────────────────────────────────
echo "==> Starting ranger..."
docker compose up -d --no-deps --force-recreate ranger

echo ""
echo "==> All services:"
docker compose ps
echo ""
echo "    Ranger API  →  http://localhost:5076/swagger"
echo "    n8n         →  http://localhost:5678"
echo "    Open WebUI  →  http://localhost:3333"
echo "    Baserow     →  http://localhost:8081"
echo "    Qdrant      →  http://localhost:6333"
