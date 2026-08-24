#!/bin/bash
# EC2 first-boot bootstrap (Amazon Linux 2023).
# Installs Docker + the compose plugin, clones the public repo, writes a .env,
# and brings the stack up. Logs go to /var/log/cloud-init-output.log.
set -euxo pipefail

# --- Docker --------------------------------------------------------------
dnf update -y
dnf install -y docker git
systemctl enable --now docker
usermod -aG docker ec2-user || true

# --- Docker Compose v2 plugin -------------------------------------------
mkdir -p /usr/libexec/docker/cli-plugins
curl -SL "https://github.com/docker/compose/releases/latest/download/docker-compose-linux-x86_64" \
  -o /usr/libexec/docker/cli-plugins/docker-compose
chmod +x /usr/libexec/docker/cli-plugins/docker-compose

# --- App -----------------------------------------------------------------
cd /opt
git clone https://github.com/Nixxs/postgis_aws_gis_poc.git
cd postgis_aws_gis_poc

# The repo does not track .env; write the PoC config the compose file needs.
cat > .env <<'EOF'
COMPOSE_PROJECT_NAME=postgis_aws_gis_poc
ENV_STATE=global
DB_NAME=postgis_aws_gis_poc
DB_USER=postgres
DB_PASSWORD=postgis_poc_pw_2026
DB_HOST=db
DB_PORT=5432
DB_SSL=disable
FRONTEND_URL=*
BACKEND_URL=*
EOF

docker compose up -d --build
