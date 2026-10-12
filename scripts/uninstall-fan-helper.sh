#!/bin/bash
# Removes pulso-fand. Stopping it returns every fan to automatic first.
#
#   sudo scripts/uninstall-fan-helper.sh
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "Ejecuta: sudo $0" >&2
    exit 1
fi

LABEL=com.jorgenchu.pulso.fand
launchctl bootout system "/Library/LaunchDaemons/$LABEL.plist" 2>/dev/null || true
rm -f "/Library/LaunchDaemons/$LABEL.plist" "/Library/PrivilegedHelperTools/$LABEL" /var/run/pulso-fand.sock

echo "Servicio de ventiladores desinstalado."
