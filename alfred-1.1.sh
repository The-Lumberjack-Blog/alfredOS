#!/bin/bash
set -e

# ----------------------------
# System Update & Docker Setup
# ----------------------------
echo "Updating system and installing required packages..."
sudo apt-get update -y
sudo apt-get install -y ca-certificates curl

echo "Adding Docker's GPG key..."
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc

echo "Adding Docker repository..."
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}") stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
sudo apt-get update -y

echo "Installing Docker and Docker Compose..."
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y docker-compose

echo "Verifying Docker installation..."
sudo docker version || { echo "Docker installation failed"; exit 1; }

if ! groups $USER | grep -q '\bdocker\b'; then
    echo "Adding user to the docker group..."
    sudo usermod -aG docker $USER
    echo "User added to docker group. You may need to restart your session."
else
    echo "User is already in the docker group."
fi

# ----------------------------
# Define Directories & Public IP
# ----------------------------
PUBLIC_IP=$(curl -s https://ipinfo.io/ip)
echo "Public IP detected: $PUBLIC_IP"

BASE_DIR="/home/ubuntu/homepage"
CONFIG_DIR="/data/config/homepage"
N8N_CONFIG_DIR="/data/config/n8n"
HOMARR_CONFIG_DIR="/data/config/homarr"
DOCKER_SCRIPTS_DIR="/data/scripts"

echo "Creating required directories."
mkdir -p "$CONFIG_DIR" "$N8N_CONFIG_DIR" "$HOMARR_CONFIG_DIR" "$DOCKER_SCRIPTS_DIR" "$BASE_DIR"

# ----------------------------
# Clone Repositories
# ----------------------------
if [ ! -d "$BASE_DIR/calcom-docker" ]; then
    git clone --recursive https://github.com/calcom/docker.git "$BASE_DIR/calcom-docker"
    cd "$BASE_DIR/calcom-docker"
    git submodule update --remote --init --recursive
    while [ ! -f "$BASE_DIR/calcom-docker/.env.example" ]; do
        echo "Waiting for .env.example to be available..."
        sleep 2
    done
    cp .env.example .env
    cd "$BASE_DIR"
else
    echo "Cal.com repository already exists. Skipping clone."
fi

if [ ! -d "$BASE_DIR/mattermost" ]; then
    git clone https://github.com/mattermost/docker "$BASE_DIR/mattermost"
    while [ ! -d "$BASE_DIR/mattermost/.git" ]; do
        echo "Waiting for Mattermost repository to be fully cloned..."
        sleep 2
    done
    cd "$BASE_DIR/mattermost"
    while [ ! -f env.example ]; do
        sleep 2
    done
    cp env.example .env
    while ! git status &>/dev/null; do
        echo "Waiting for Mattermost files to be fully written..."
        sleep 2
    done
    sudo chown -R 2000:2000 "$BASE_DIR/mattermost"
    cd "$BASE_DIR"
else
    echo "Mattermost repository already exists. Skipping clone."
fi

# ----------------------------
# Jitsi Configuration
# ----------------------------
JITSI_RELEASE_URL=$(curl -s https://api.github.com/repos/jitsi/docker-jitsi-meet/releases/latest | grep 'zip' | cut -d\" -f4)
JITSI_FILENAME=$(basename "$JITSI_RELEASE_URL")
echo "Downloading Jitsi release: $JITSI_FILENAME"
wget "$JITSI_RELEASE_URL" -O "$BASE_DIR/$JITSI_FILENAME"

if ! command -v unzip &> /dev/null; then
    echo "Installing unzip."
    export DEBIAN_FRONTEND=noninteractive
    sudo apt-get update -y && sudo apt-get install -y unzip
fi

echo "Extracting Jitsi."
unzip "$BASE_DIR/$JITSI_FILENAME" -d "$BASE_DIR"

JITSI_DIR=$(find "$BASE_DIR" -maxdepth 1 -type d -name "jitsi-docker-jitsi-meet*")
if [ -d "$JITSI_DIR" ]; then
    echo "Setting up Jitsi in $JITSI_DIR"
    cd "$JITSI_DIR"
    cp env.example .env
    sed -i 's/^HTTPS_PORT=8443$/HTTPS_PORT=8444/' .env
    ./gen-passwords.sh
    mkdir -p ~/.jitsi-meet-cfg/{web,transcripts,prosody/config,prosody/prosody-plugins-custom,jicofo,jvb,jigasi,jibri}
    sed -i "s|- '\${HTTP_PORT}:80'|- '$PUBLIC_IP:\${HTTP_PORT}:80'|" docker-compose.yml
    sed -i "s|- '\${HTTPS_PORT}:443'|- '$PUBLIC_IP:\${HTTPS_PORT}:8444'|" docker-compose.yml
else
    echo "Error: Jitsi extraction failed. Directory not found."
    exit 1
fi

# ----------------------------
# Create Docker Volumes & Set Permissions
# ----------------------------
echo "Creating Docker volumes."
docker volume create yacht_data
docker volume create open-webui

echo "Setting permissions."
chmod -R 755 "$BASE_DIR"

# ----------------------------
# Homepage Dashboard Configurations
# ----------------------------
DOCKER_YAML="$CONFIG_DIR/docker.yaml"
if [ ! -f "$DOCKER_YAML" ]; then
    cat <<EOF > "$DOCKER_YAML"
my-docker:
  socket: /var/run/docker.sock

widgets:
  - docker:
      server: my-docker
      containers:
        - homepage
        - n8n
        - calcom-docker-calcom-1
        - calcom-docker-studio-1
        - openwebui
        - excalidraw
        - mattermost
        - homarr
        - yacht
        - jitsi-docker-jitsi-meet-6ab6f1e_web_1
        - jitsi-docker-jitsi-meet-6ab6f1e_jicofo_1
        - jitsi-docker-jitsi-meet-6ab6f1e_jvb_1
        - jitsi-docker-jitsi-meet-6ab6f1e_prosody_1
      showEventLog: true
      showStopped: true
      actions: true
EOF
else
    echo "docker.yaml already exists. Skipping creation."
fi

SERVICES_YAML="$CONFIG_DIR/services.yaml"
if [ ! -f "$SERVICES_YAML" ]; then
    cat <<EOF > "$SERVICES_YAML"
- Productivity:
    - n8n:
        icon: n8n.svg
        href: http://$PUBLIC_IP:5679
        description: Workflow automation tool

    - Cal.com:
        icon: calcom.svg
        href: http://$PUBLIC_IP:3000
        description: Open-source scheduling

    - Calcom Studio:
        icon: calcom.svg
        href: http://$PUBLIC_IP:5555
        description: Prisma Studio for Cal.com database

- Development:
    - OpenWebUI:
        icon: openwebui.svg
        href: http://$PUBLIC_IP:3002
        description: Open-source AI interface

- Collaboration:
    - Mattermost:
        icon: mattermost.svg
        href: http://$PUBLIC_IP:8065
        description: Self-hosted chat & team communication

    - Jitsi Meet:
        icon: jitsi.svg
        href: http://$PUBLIC_IP:8000
        description: Video conferencing

- Design & Creativity:
    - Excalidraw:
        icon: excalidraw.svg
        href: http://$PUBLIC_IP:8081
        description: Open-source whiteboard

- Dashboard:
    - Homarr:
        icon: homarr.svg
        href: http://$PUBLIC_IP:7575
        description: Homepage dashboard

    - Container Control:
        widget: iframe
        href: "http://$PUBLIC_IP:5003/ui"
        description: "Start/Stop Containers"
        height: 300px
        width: full

    - Yacht:
        icon: yacht.svg
        href: http://$PUBLIC_IP:8001
        description: Web-based container management UI

- Teable:
    - Teable:
        icon: teable.svg
        href: http://$PUBLIC_IP:3003
        description: Teable service for URL shortening and management.

- Supabase:
    - Supabase Studio:
        icon: supabase.svg
        href: http://$PUBLIC_IP:3100
        description: Supabase Studio for database management and API.
EOF
else
    echo "services.yaml already exists. Skipping creation."
fi

cat <<EOF > "$BASE_DIR/docker-compose.yml"
version: '3.8'

services:
  homepage:
    image: ghcr.io/gethomepage/homepage:latest
    container_name: homepage
    ports:
      - "$PUBLIC_IP:3001:3000"
    volumes:
      - /data/config/homepage:/app/config
      - /var/run/docker.sock:/var/run/docker.sock
    networks:
      - homepage_network
    restart: unless-stopped

  n8n:
    image: n8nio/n8n
    container_name: n8n
    ports:
      - "$PUBLIC_IP:5679:5678"
    volumes:
      - /data/config/n8n:/root/.n8n
    environment:
      - N8N_BASIC_AUTH_ACTIVE=true
      - N8N_BASIC_AUTH_USER=admin
      - N8N_BASIC_AUTH_PASSWORD=securepassword
      - N8N_SECURE_COOKIE=false
    networks:
      - homepage_network
    restart: unless-stopped

  openwebui:
    image: ghcr.io/open-webui/open-webui:latest
    container_name: openwebui
    ports:
      - "$PUBLIC_IP:3002:8080"
    volumes:
      - open-webui:/app/backend/data
    environment:
      - WEBUI_HOST=0.0.0.0
    networks:
      - homepage_network
    restart: unless-stopped

  excalidraw:
    image: excalidraw/excalidraw
    container_name: excalidraw
    ports:
      - "$PUBLIC_IP:8081:80"
    networks:
      - homepage_network
    restart: unless-stopped

  homarr:
    image: ghcr.io/ajnart/homarr:latest
    container_name: homarr
    ports:
      - "$PUBLIC_IP:7575:7575"
    volumes:
      - /data/config/homarr:/app/data/config
    networks:
      - homepage_network
    restart: unless-stopped

  yacht:
    image: selfhostedpro/yacht
    container_name: yacht
    ports:
      - "$PUBLIC_IP:8001:8000"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - yacht_data:/config
    networks:
      - homepage_network
    restart: unless-stopped

  docker-api:
    image: tiangolo/uwsgi-nginx-flask:python3.8
    container_name: docker-api
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - /data/scripts:/app
    environment:
      - FLASK_APP=app.py
    ports:
      - "$PUBLIC_IP:5003:5003"
    networks:
      - homepage_network
    restart: unless-stopped
    command: flask run --host=0.0.0.0 --port=5003

networks:
  homepage_network:
    driver: bridge

volumes:
  yacht_data:
  open-webui:
EOF

# ----------------------------
# Start/Stop Scripts for Homepage
# ----------------------------
echo "Creating start.sh script."
cat <<EOF > "$BASE_DIR/start.sh"
#!/bin/bash
# Start the main compose
docker-compose up -d
# Start the Calcom sub-compose
(cd calcom-docker && docker compose up -d)
sudo chown -R 2000:2000 mattermost/
(cd mattermost && sudo docker compose -f docker-compose.yml -f docker-compose.without-nginx.yml up -d)
# Start Jitsi
JITSI_DIR=\$(find "$BASE_DIR" -maxdepth 1 -type d -name "jitsi-docker-jitsi-meet*")
if [ -d "\$JITSI_DIR" ]; then
    (cd "\$JITSI_DIR" && docker-compose up -d)
else
    echo "Jitsi directory not found. Skipping Jitsi startup."
fi
EOF
chmod +x "$BASE_DIR/start.sh"

echo "Creating stop.sh script."
cat <<EOF > "$BASE_DIR/stop.sh"
#!/bin/bash
# Stop the main compose
docker-compose down
# Stop the Calcom sub-compose
(cd calcom-docker && docker-compose down)
(cd mattermost && sudo docker compose down)
# Stop Jitsi
JITSI_DIR=\$(find "$BASE_DIR" -maxdepth 1 -type d -name "jitsi-docker-jitsi-meet*")
if [ -d "\$JITSI_DIR" ]; then
    (cd "\$JITSI_DIR" && docker-compose down)
else
    echo "Jitsi directory not found. Skipping Jitsi shutdown."
fi
EOF
chmod +x "$BASE_DIR/stop.sh"

# ----------------------------
# Embedded Teable Section
# ----------------------------
echo "Setting up Teable environment..."
TEABLE_DIR="$BASE_DIR/teable"
mkdir -p "$TEABLE_DIR"

echo "Creating teable docker-compose.yml in $TEABLE_DIR."
cat <<'EOF' > "$TEABLE_DIR/docker-compose.yml"
services:
  teable:
    image: ghcr.io/teableio/teable-ee:latest
    restart: always
    ports:
      - '3003:3000'
    volumes:
      - teable-data:/app/.assets:rw
    env_file:
      - .env
    environment:
      - NEXT_ENV_IMAGES_ALL_REMOTE=true
    networks:
      - teable
    depends_on:
      teable-db-migrate:
        condition: service_completed_successfully
      teable-cache:
        condition: service_healthy
    healthcheck:
      test: ['CMD', 'curl', '-f', 'http://localhost:3000/health']
      start_period: 5s
      interval: 5s
      timeout: 3s
      retries: 3

  teable-db:
    image: postgres:15.4
    restart: always
    ports:
      - '42345:5432'
    volumes:
      - teable-db:/var/lib/postgresql/data:rw
    environment:
      - POSTGRES_DB=${POSTGRES_DB}
      - POSTGRES_USER=${POSTGRES_USER}
      - POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
    networks:
      - teable
    healthcheck:
      test: ['CMD-SHELL', "sh -c 'pg_isready -U ${POSTGRES_USER} -d ${POSTGRES_DB}'"]
      interval: 10s
      timeout: 3s
      retries: 3

  teable-db-migrate:
    image: ghcr.io/teableio/teable-db-migrate-ee:latest
    environment:
      - PRISMA_DATABASE_URL=postgresql://${POSTGRES_USER}:${POSTGRES_PASSWORD}@${POSTGRES_HOST}:${POSTGRES_PORT}/${POSTGRES_DB}
    networks:
      - teable
    depends_on:
      teable-db:
        condition: service_healthy

  teable-cache:
    image: redis:7.2.4
    restart: always
    expose:
      - '6379'
    volumes:
      - teable-cache:/data:rw
    networks:
      - teable
    command: redis-server --appendonly yes --requirepass ${REDIS_PASSWORD}
    healthcheck:
      test: ['CMD', 'redis-cli', '--raw', 'incr', 'ping']
      interval: 10s
      timeout: 3s
      retries: 3

networks:
  teable:
    name: teable-network

volumes:
  teable-db: {}
  teable-data: {}
  teable-cache: {}
EOF

echo "Creating teable .env file in $TEABLE_DIR."
cat <<'EOF' > "$TEABLE_DIR/.env"
# Replace the default password below with a strong password (ASCII) of at least 8 characters.
POSTGRES_PASSWORD=admin
REDIS_PASSWORD=admin
SECRET_KEY=admin

# Replace the following with a publicly accessible address
PUBLIC_ORIGIN=http://__PUBLIC_IP__:3003

# ---------------------

# Postgres
POSTGRES_HOST=teable-db
POSTGRES_PORT=5432
POSTGRES_DB=teable
POSTGRES_USER=teable

# Redis
REDIS_HOST=teable-cache
REDIS_PORT=6379
REDIS_DB=0

# App
PRISMA_DATABASE_URL=postgresql://${POSTGRES_USER}:${POSTGRES_PASSWORD}@${POSTGRES_HOST}:${POSTGRES_PORT}/${POSTGRES_DB}
BACKEND_CACHE_PROVIDER=redis
BACKEND_CACHE_REDIS_URI=redis://default:${REDIS_PASSWORD}@${REDIS_HOST}:${REDIS_PORT}/${REDIS_DB}
EOF
sed -i "s/__PUBLIC_IP__/$PUBLIC_IP/g" "$TEABLE_DIR/.env"

cd "$TEABLE_DIR"
echo "Pulling teable images..."
docker-compose pull
echo "Starting teable containers..."
docker-compose up -d
cd "$BASE_DIR"

# ----------------------------
# Embedded Supabase Section
# ----------------------------
echo "Setting up Supabase environment..."
SUPABASE_DIR="$BASE_DIR/supabase"
git clone --depth 1 https://github.com/supabase/supabase "$SUPABASE_DIR"
cd "$SUPABASE_DIR/docker"
cp .env.example .env
sed -i "s|^SITE_URL=http://localhost:3000|SITE_URL=http://$PUBLIC_IP:3100|" .env
sed -i "s|^STUDIO_PORT=3000|STUDIO_PORT=3100|" .env
sed -i "s|^API_EXTERNAL_URL=http://localhost:8000|API_EXTERNAL_URL=http://$PUBLIC_IP:8100|" .env
sed -i "s|^KONG_HTTP_PORT=8000|KONG_HTTP_PORT=8100|" .env
sed -i "s|^KONG_HTTPS_PORT=8443|KONG_HTTPS_PORT=8445|" .env
sed -i "s|^SUPABASE_PUBLIC_URL=http://localhost:8000|SUPABASE_PUBLIC_URL=http://$PUBLIC_IP:8100|" .env
docker compose pull
docker compose up -d
cd "$BASE_DIR"

# ----------------------------
# Python API & Container Control UI
# ----------------------------
echo "Creating Python API script."
cat <<EOF > "/data/scripts/app.py"
from flask import Flask, jsonify, send_from_directory
import subprocess
import os

app = Flask(__name__)

# Get public IP dynamically
PUBLIC_IP = os.getenv('PUBLIC_IP', '$PUBLIC_IP')

# List of containers to control
CONTAINERS = [
    {"name": "homepage"},
    {"name": "n8n"},
    {"name": "calcom-docker-calcom-1"},
    {"name": "calcom-docker-studio-1"},
    {"name": "openwebui"},
    {"name": "excalidraw"},
    {"name": "mattermost"},
    {"name": "homarr"},
    {"name": "yacht"},
    {"name": "jitsi-docker-jitsi-meet-6ab6f1e_web_1"},
    {"name": "jitsi-docker-jitsi-meet-6ab6f1e_jicofo_1"},
    {"name": "jitsi-docker-jitsi-meet-6ab6f1e_jvb_1"},
    {"name": "jitsi-docker-jitsi-meet-6ab6f1e_prosody_1"}
]

@app.route('/containers', methods=['GET'])
def list_containers():
    return jsonify({"containers": CONTAINERS})

@app.route('/start/<container>', methods=['POST'])
def start_container(container):
    result = subprocess.run([
        "curl", "--unix-socket", "/var/run/docker.sock", "-X", "POST",
        f"http://{PUBLIC_IP}/containers/{container}/start"
    ], capture_output=True, text=True)
    if result.returncode != 0:
        return jsonify({"error": "Failed to start container", "details": result.stderr}), 500
    return jsonify({"status": "started", "container": container})

@app.route('/stop/<container>', methods=['POST'])
def stop_container(container):
    result = subprocess.run([
        "curl", "--unix-socket", "/var/run/docker.sock", "-X", "POST",
        f"http://{PUBLIC_IP}/containers/{container}/stop"
    ], capture_output=True, text=True)
    if result.returncode != 0:
        return jsonify({"error": "Failed to stop container", "details": result.stderr}), 500
    return jsonify({"status": "stopped", "container": container})

@app.route('/ui', methods=['GET'])
def serve_ui():
    return send_from_directory('/app/ui', 'index.html')

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=5003)
EOF

echo "Creating UI HTML for Container Control."
mkdir -p "/data/scripts/ui"
cat <<EOF > "/data/scripts/ui/index.html"
<!DOCTYPE html>
<html>
<head>
    <title>Container Control</title>
    <style>
        body {
            font-family: Arial, sans-serif;
            text-align: center;
            margin: 0;
            padding: 0;
        }
        select, button {
            padding: 8px;
            margin: 5px;
            font-size: 16px;
        }
    </style>
    <script>
        const PUBLIC_IP = "$PUBLIC_IP";

        async function fetchContainers() {
            const response = await fetch(\`http://\${PUBLIC_IP}:5003/containers\`);
            const data = await response.json();
            const containerSelect = document.getElementById("containerSelect");
            containerSelect.innerHTML = "";
            data.containers.forEach(container => {
                const option = document.createElement("option");
                option.value = container.name;
                option.textContent = container.name;
                containerSelect.appendChild(option);
            });
        }

        async function controlContainer(action) {
            const container = document.getElementById("containerSelect").value;
            if (!container) {
                alert("No container selected!");
                return;
            }
            await fetch(\`http://\${PUBLIC_IP}:5003/\${action}/\${container}\`, { method: "POST" });
            alert(\`\${container} \${action}ed!\`);
        }

        window.onload = fetchContainers;
    </script>
</head>
<body>
    <h3>Container Control</h3>
    <select id="containerSelect"></select>
    <button onclick="controlContainer('start')">Start</button>
    <button onclick="controlContainer('stop')">Stop</button>
</body>
</html>
EOF

echo "Setup complete."
