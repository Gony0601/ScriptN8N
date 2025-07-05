#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

#------------------------------------------------------
# install-n8n.sh
# 1) Instala Docker & Docker Compose si faltan
# 2) Despliega n8n en Docker (modo LOCAL o VPS con -d dominio)
# 3) Configura Nginx/HTTPS/firewall en VPS
# 4) Verifica que n8n esté corriendo, puerto LISTEN y HTTP(S)
#
# Uso:
#   sudo ./install-n8n.sh            # local: acceso por IP:5678
#   sudo ./install-n8n.sh -d dominio.com
#     # VPS: acceso https://dominio.com
#------------------------------------------------------

DOMAIN=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -d|--domain)
      DOMAIN="$2"; shift 2
      ;;
    -h|--help)
      echo "Usage: $0 [-d domain]"
      exit 0
      ;;
    *)
      echo "ERROR: opción desconocida: $1" >&2
      exit 1
      ;;
  esac
done

# 0) Debe ejecutarse como root
if [[ $EUID -ne 0 ]]; then
  echo "ERROR: ejecuta este script como root." >&2
  exit 1
fi

# Función genérica para instalar paquetes
install_pkgs() {
  if command -v apt-get &>/dev/null; then
    DEBIAN_FRONTEND=noninteractive apt-get update -qq
    apt-get install -y "$@"
  elif command -v yum &>/dev/null; then
    yum install -y "$@"
  else
    echo "ERROR: ni apt-get ni yum disponibles." >&2
    exit 1
  fi
}

# 1) Instalar Docker si falta
if ! command -v docker &>/dev/null; then
  echo ">>> Instalando Docker..."
  install_pkgs docker.io
  systemctl enable --now docker
else
  echo ">>> Docker ya instalado."
fi

# 1b) Instalar Docker Compose si falta
if ! command -v docker-compose &>/dev/null; then
  echo ">>> Instalando Docker Compose plugin..."
  install_pkgs docker-compose-plugin || true
  if command -v docker-compose-plugin &>/dev/null; then
    ln -sf "$(command -v docker-compose-plugin)" /usr/local/bin/docker-compose
  else
    echo " — Descargando docker-compose binario..."
    curl -fsSL "https://github.com/docker/compose/releases/download/v2.20.2/docker-compose-$(uname -s)-$(uname -m)" \
      -o /usr/local/bin/docker-compose
    chmod +x /usr/local/bin/docker-compose
  fi
else
  echo ">>> Docker Compose ya instalado."
fi

# 2) Preparar datos y compose
echo ">>> Preparando datos en /opt/n8n/data..."
mkdir -p /opt/n8n/data
chown -R 1000:1000 /opt/n8n/data

echo ">>> Generando /opt/n8n/docker-compose.yml..."
mkdir -p /opt/n8n
cat > /opt/n8n/docker-compose.yml <<EOF
version: "3.8"
services:
  n8n:
    image: n8nio/n8n:latest
    restart: unless-stopped
    ports:
      - "5678:5678"
    environment:
      - N8N_HOST=${DOMAIN:-0.0.0.0}
      - N8N_PORT=5678
      - N8N_ENFORCE_SETTINGS_FILE_PERMISSIONS=true
      - N8N_SECURE_COOKIE=false
${DOMAIN:+      - WEBHOOK_TUNNEL_URL=https://${DOMAIN}}
    volumes:
      - /opt/n8n/data:/home/node/.n8n
# Se usa el entrypoint/CMD por defecto de la imagen
EOF

# 3) Si es VPS: configurar Nginx + HTTPS + UFW
if [[ -n "$DOMAIN" ]]; then
  echo ">>> Instalando Nginx, Certbot y UFW..."
  install_pkgs nginx certbot python3-certbot-nginx ufw

  echo ">>> Configurando UFW..."
  ufw default deny incoming
  ufw default allow outgoing
  ufw allow OpenSSH
  ufw allow 'Nginx Full'
  ufw --force enable

  echo ">>> Configurando Nginx para $DOMAIN..."
  cat > /etc/nginx/sites-available/n8n.conf <<NGINX
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
NGINX
  ln -sf /etc/nginx/sites-available/n8n.conf /etc/nginx/sites-enabled/
  nginx -t && systemctl reload nginx

  echo ">>> Solicitando certificado Let's Encrypt..."
  certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos -m webmaster@"$DOMAIN"
else
  echo ">>> Modo LOCAL: n8n accesible por IP:5678"
fi

# 4) Desplegar n8n
echo ">>> Desplegando n8n con Docker Compose..."
cd /opt/n8n
docker-compose up -d

# 5) Verificar contenedor
echo ">>> Verificando contenedor n8n..."
if ! docker ps --filter name=n8n --filter status=running --quiet | grep -q .; then
  echo "ERROR: contenedor n8n no está en ejecución." >&2
  exit 1
fi
echo "✓ Contenedor OK"

# 6) Verificar puerto 5678
echo ">>> Verificando puerto 5678..."
if ! ss -tln | grep -q ":5678 "; then
  echo "ERROR: puerto 5678 no está escuchando." >&2
  exit 1
fi
echo "✓ Puerto LISTEN"

# 7) Probar HTTP(S)
if [[ -n "$DOMAIN" ]]; then
  URL="https://$DOMAIN"
else
  IP=$(hostname -I | awk '{print $1}')
  URL="http://$IP:5678"
fi
echo ">>> Probando acceso a $URL..."
if curl -sfI "$URL" | grep -q "HTTP/"; then
  echo "✅ n8n responde correctamente en $URL"
else
  echo "ERROR: no hay respuesta HTTP en $URL" >&2
  exit 1
fi

echo "🎉 Instalación y verificación completadas."
