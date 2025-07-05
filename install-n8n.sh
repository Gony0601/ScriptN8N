#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

#------------------------------------------------------
# Script para instalar N8N en Docker:
# - Local (por defecto)
# - VPS con subdominio y HTTPS (si se pasa -d dominio)
#
# Uso:
#   ./install-n8n.sh            # instalación local
#   ./install-n8n.sh -d midominio.com
#------------------------------------------------------

# Variables
DOMAIN=""
SCRIPT_NAME=$(basename "$0")

# Función de ayuda
usage() {
  cat <<EOF
Uso: $SCRIPT_NAME [-h] [-d dominio]
  -h            Muestra esta ayuda
  -d dominio    Instala en VPS, configura subdominio y HTTPS
Sin -d se instala en local y expone puerto 5678.
EOF
  exit 1
}

# Parsear opciones
while getopts "hd:" opt; do
  case "$opt" in
    h) usage ;;
    d) DOMAIN=$OPTARG ;;
    *) usage ;;
  esac
done

# Comprobar permisos root
if [[ $EUID -ne 0 ]]; then
  echo "¡Error! Debes ejecutar este script como root o con sudo." >&2
  exit 1
fi

# Detectar gestor de paquetes
install_pkg() {
  local pkgs=("$@")
  if command -v apt-get >/dev/null; then
    apt-get update
    apt-get install -y "${pkgs[@]}"
  elif command -v yum >/dev/null; then
    yum install -y "${pkgs[@]}"
  else
    echo "Gestor de paquetes no soportado (apt-get, yum)." >&2
    exit 1
  fi
}

# Instalar Docker + Docker Compose
echo "Instalando Docker y Docker Compose si es necesario..."
if ! command -v docker >/dev/null; then
  install_pkg docker.io
fi
if ! command -v docker-compose >/dev/null; then
  install_pkg docker-compose
fi

# Crear docker-compose.yml
cat > /opt/n8n-docker-compose.yml <<'EOF'
version: '3.8'
services:
  n8n:
    image: n8nio/n8n:latest
    restart: always
    ports:
      - "5678:5678"
    environment:
      - N8N_HOST=${DOMAIN:-localhost}
      - N8N_PORT=5678
      - WEBHOOK_TUNNEL_URL=${DOMAIN:+https://${DOMAIN}}
    volumes:
      - /opt/n8n-data:/home/node/.n8n
EOF

# Si se especificó dominio => VPS
if [[ -n "$DOMAIN" ]]; then
  echo "Configurando VPS con subdominio ${DOMAIN} y HTTPS..."

  # Instalar Nginx y Certbot
  install_pkg nginx certbot python3-certbot-nginx

  # Configurar bloque de servidor
  cat > /etc/nginx/sites-available/n8n.conf <<EOF
server {
    listen 80;
    server_name $DOMAIN;
    location / {
        proxy_pass http://127.0.0.1:5678;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
    }
}
EOF

  ln -sf /etc/nginx/sites-available/n8n.conf /etc/nginx/sites-enabled/
  nginx -t
  systemctl reload nginx

  # Obtener certificado
  certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos -m webmaster@"$DOMAIN"

  # Levantar N8N con Docker Compose
  echo "Iniciando N8N en Docker..."
  docker-compose -f /opt/n8n-docker-compose.yml up -d

  echo "✅ N8N instalado en VPS"
  echo "Accede a: https://$DOMAIN"
else
  # Instalación local
  echo "Instalación local. Se expondrá en http://localhost:5678"
  docker-compose -f /opt/n8n-docker-compose.yml up -d
  echo "✅ N8N instalado localmente"
  echo "Accede a: http://localhost:5678"
fi

exit 0
