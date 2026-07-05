#!/usr/bin/env bash
set -euo pipefail

SUPPORT_DIR="$HOME/Library/Application Support/PrintArk/cainiao-wss"
CERT="$SUPPORT_DIR/server.crt"
KEY="$SUPPORT_DIR/server.key"
OFFICIAL_JAR="/Applications/cainiao-x-print.app/Contents/Resources/Xprint.xjar"

mkdir -p "$SUPPORT_DIR"

if [[ ! -f "$CERT" || ! -f "$KEY" ]]; then
  if [[ ! -f "$OFFICIAL_JAR" ]]; then
    echo "missing $OFFICIAL_JAR; install Cainiao X Print once or provide $CERT and $KEY"
    exit 1
  fi
  /usr/bin/unzip -p "$OFFICIAL_JAR" ca/server.crt > "$CERT"
  /usr/bin/unzip -p "$OFFICIAL_JAR" ca/server.key > "$KEY"
  chmod 600 "$KEY"
fi

/usr/bin/osascript <<APPLESCRIPT
set certPath to "$CERT"
do shell script "security add-trusted-cert -d -r trustAsRoot -p ssl -k /Library/Keychains/System.keychain " & quoted form of certPath with administrator privileges
APPLESCRIPT

echo "installed trusted localhost certificate for PrintArk WSS"
