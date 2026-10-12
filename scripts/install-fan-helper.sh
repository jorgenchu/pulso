#!/bin/bash
# Installs pulso-fand, the root helper that lets Pulso set fan speeds.
# Writing to the SMC needs root, so this has to be run by you, with sudo.
#
# From an installed copy of the app (the helper comes built inside it):
#
#   sudo /Applications/Pulso.app/Contents/Resources/install-fan-helper.sh
#
# From the sources (the helper is built first):
#
#   sudo scripts/install-fan-helper.sh
#
# Undo it with uninstall-fan-helper.sh, which sits next to this script.
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "Ejecuta: sudo \"$0\"" >&2
    exit 1
fi
# The helper only takes orders from the user who installs it.
USER_ID="${SUDO_UID:?Ejecuta este script con sudo desde tu usuario, no como root directamente}"

HERE="$(cd "$(dirname "$0")" && pwd)"
LABEL=com.jorgenchu.pulso.fand
HELPER="/Library/PrivilegedHelperTools/$LABEL"
PLIST="/Library/LaunchDaemons/$LABEL.plist"

if [[ -x "$HERE/../Helpers/pulso-fand" ]]; then
    BIN="$HERE/../Helpers/pulso-fand"
else
    # Build as the invoking user, so nothing in the project ends up owned by root.
    cd "$HERE/.."
    sudo -u "#$USER_ID" swift build -c release --product pulso-fand
    BIN="$(sudo -u "#$USER_ID" swift build -c release --show-bin-path)/pulso-fand"
fi

launchctl bootout system "$PLIST" 2>/dev/null || true
install -d -o root -g wheel -m 755 /Library/PrivilegedHelperTools
install -o root -g wheel -m 755 "$BIN" "$HELPER"
# A copy that came from a downloaded disk image is still marked as such, and launchd
# will not start a quarantined program.
xattr -d com.apple.quarantine "$HELPER" 2>/dev/null || true

cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>$LABEL</string>
	<key>ProgramArguments</key>
	<array>
		<string>$HELPER</string>
		<string>--uid</string>
		<string>$USER_ID</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<true/>
</dict>
</plist>
EOF
chown root:wheel "$PLIST"
chmod 644 "$PLIST"
launchctl bootstrap system "$PLIST"

echo "Servicio de ventiladores instalado."
