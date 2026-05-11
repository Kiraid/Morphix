#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "Fetching infrastructure outputs..."
API="$(terraform -chdir=terraform output -raw api_gateway_url)"
HOST="$(terraform -chdir=terraform output -raw iot_endpoint)"

IOT_WS="wss://${HOST}/mqtt"
AUTH="${API}/iot-auth"

echo "Injecting values into frontend/app.js..."
sed -i \
  -e "s#{{API_BASE_URL}}#${API}#g" \
  -e "s#{{IOT_ENDPOINT_URL}}#${IOT_WS}#g" \
  -e "s#{{IOT_AUTH_URL}}#${AUTH}#g" \
  frontend/app.js

echo "Injection complete."