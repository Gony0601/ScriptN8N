#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

#------------------------------------------------------
# verify-n8n.sh
# Verifica que n8n esté corriendo, que el puerto 5678
# esté LISTEN y lo abre en UFW si falta,
# y finalmente comprueba HTTP.
#
# Uso:
#   sudo ./verify-n8n.sh [host]
#     host: dominio o IP (por defecto se toma primera IP local)
#------------------------------------------------------

HOST="${1:-\$(hostname -I | awk '{print \$1}')}"
PORT=5678

echo ">>> Comprobando contenedor n8n..."
if ! docker ps --filter "publish=\${PORT}/tcp" --format '{{.Names}}' | grep -q .; then
  echo "ERROR: No hay contenedor publicando puerto \$PORT." >&2
  exit 1
fi
echo "✓ Contenedor OK."

echo ">>> Verificando puerto \$PORT en el host..."
if ! ss -tln | grep -q ":\\\$PORT "; then
  echo "Puerto \$PORT no está LISTEN."
  if command -v ufw &>/dev/null; then
    echo "Abriendo \$PORT en UFW..."
    ufw allow \$PORT/tcp && ufw reload
    echo "✓ Puerto \$PORT abierto."
  else
    echo "ERROR: ufw no instalado. Abre el puerto manualmente." >&2
    exit 1
  fi
else
  echo "✓ Puerto \$PORT está LISTEN."
fi

echo ">>> Probando HTTP en http://\$HOST:\$PORT ..."
if curl -sfI http://"\$HOST":"\$PORT" | grep -q 'HTTP/'; then
  echo "✅ n8n responde correctamente."
else
  echo "ERROR: no se obtuvo respuesta HTTP." >&2
  exit 1
fi

echo "¡Todo funcionando!" 
