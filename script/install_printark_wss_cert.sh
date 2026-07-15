#!/usr/bin/env bash
set -euo pipefail

SUPPORT_DIR="$HOME/Library/Application Support/PrintArk/localhost-tls"
CERT="$SUPPORT_DIR/server.crt"

if [[ ! -f "$CERT" ]]; then
  echo "missing $CERT; open PrintArk once so it can generate its localhost certificate" >&2
  exit 1
fi

/usr/bin/security add-trusted-cert \
  -r trustRoot \
  -p ssl \
  -k "$HOME/Library/Keychains/login.keychain-db" \
  "$CERT"

/usr/bin/security verify-cert -c "$CERT" -p ssl -n localhost -L -q
echo "installed trusted PrintArk localhost certificate"
