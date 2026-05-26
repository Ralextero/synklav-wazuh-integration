#!/bin/bash

# ==============================================================================
# SYNKLAV - AUTOMATED MULTI-MODE WAZUH INTEGRATION DEPLOYMENT MANIFEST
# ==============================================================================

# Enforce root privileges
if [ "$EUID" -ne 0 ]; then
  echo "[ERROR] Security context execution violation: Script must be run as root (sudo)."
  exit 1
fi

echo "===================================================="
echo " SYNKLAV HUB SYSTEM INTEGRATION ENGINE              "
echo "===================================================="

OSSEC_CONF="/var/ossec/etc/ossec.conf"
WORKER_URL="https://synklav-notification-hub.synklav.workers.dev/"

# SYSTEM MODE SELECTION
echo "Select execution profile:"
echo " 1) INITIALIZE : Fresh deployment of Synklav core."
echo " 2) UPDATE     : Append a new multi-tenant node / user profile."
echo " 3) PURGE      : Complete atomic removal of all Synklav structures."
read -p "➔ Enter profile selection (1-3): " EXEC_PROFILE

# ------------------------------------------------------------------------------
# PROFILE 3: PURGE OPERATION
# ------------------------------------------------------------------------------
if [ "$EXEC_PROFILE" == "3" ]; then
  echo "[WARNING] Initializing complete system purge of Synklav assets..."
  
  # Structural backup
  cp "$OSSEC_CONF" "${OSSEC_CONF}.bak"
  
  # Safely wipe any custom-synklav python handlers inside the integration directory
  rm -f /var/ossec/integrations/custom-synklav*
  
  # Atomic removal of blocks wrapped inside Synklav anchors
  if grep -q "" "$OSSEC_CONF"; then
    sed -i '//,//d' "$OSSEC_CONF"
    echo "[STATUS] Synklav integration block stripped from ossec.conf cleanly."
  else
    echo "[STATUS] No anchor tags found. Scanning for legacy loose integrations..."
    # Fallback safe individual configuration block deletion line
    sed -i '/<integration>/,/<\/integration>/{/custom-synklav/d}' "$OSSEC_CONF"
  fi
  
  echo "[STATUS] Hot-rebooting Wazuh engine process core..."
  /var/ossec/bin/wazuh-control restart
  echo "===================================================="
  echo " 🔥 PURGE OPERATION COMPLETE: SYSTEM RESTORED CLEANLY"
  echo "===================================================="
  exit 0
fi

# ------------------------------------------------------------------------------
# PROFILES 1 & 2: DATA ACQUISITION
# ------------------------------------------------------------------------------
if [ "$EXEC_PROFILE" != "1" ] && [ "$EXEC_PROFILE" != "2" ]; then
  echo "[ERROR] Invalid selection matrix context."
  exit 1
fi

read -p "➔ Enter target UNIQUE NODE UID: " NODE_UID
NODE_UID=$(echo "$NODE_UID" | tr -d '[:space:]')

read -p "➔ Enter 24-word Recovery Kit (single space-separated line): " RECOVERY_KIT
RECOVERY_KIT=$(echo "$RECOVERY_KIT" | tr -s ' ' | tr '[:upper:]' '[:lower:]')

WORD_COUNT=$(echo "$RECOVERY_KIT" | wc -w)
if [ "$WORD_COUNT" -ne 24 ]; then
  echo "[ERROR] Cryptographic validation failure: Mnemonic matrix must equal 24 elements. Detected: $WORD_COUNT"
  exit 1
fi

read -p "➔ Activate Multi-Tenant / Custom OneSignal routing? (yes/no): " IS_CUSTOM
CUSTOM_APP_ID="null"
CUSTOM_REST_KEY="null"

if [[ "$IS_CUSTOM" =~ ^([yY][eE][sS]|[yY])$ ]]; then
  read -p "   - App ID string: " CUSTOM_APP_ID
  CUSTOM_APP_ID=$(echo "$CUSTOM_APP_ID" | tr -d '[:space:]')
  read -p "   - REST API Key string: " CUSTOM_REST_KEY
  CUSTOM_REST_KEY=$(echo "$CUSTOM_REST_KEY" | tr -d '[:space:]')
fi

read -p "➔ Active secondary Telegram notification routing? (yes/no): " IS_TELEGRAM
TG_CHAT_ID="null"

if [[ "$IS_TELEGRAM" =~ ^([yY][eE][sS]|[yY])$ ]]; then
  read -p "   - Target Chat ID string: " TG_CHAT_ID
  TG_CHAT_ID=$(echo "$TG_CHAT_ID" | tr -d '[:space:]')
fi

if [ -z "$NODE_UID" ]; then
    echo "[ERROR] Required initialization variable missing: NODE_UID cannot be null."
    exit 1
fi

echo "[STATUS] Computing symmetric cryptographic key derivations via BIP39..."

# DETERMINISTIC CIPHER GENERATION
HASHES=$(python3 -c "
import hashlib
import binascii

mnemonic_text = '$RECOVERY_KIT'.strip().encode('utf-8')
salt = b'mnemonic'

full_seed = hashlib.pbkdf2_hmac('sha512', mnemonic_text, salt, 2048, 64)
master_key_bytes = full_seed[0:32]
master_key_hex = binascii.hexlify(master_key_bytes).decode('utf-8')

node_uid = '$NODE_UID'
notification_key_input = (node_uid + master_key_hex).encode('utf-8')
notification_key = hashlib.sha256(notification_key_input).hexdigest()

tag_input = (notification_key + node_uid).encode('utf-8')
onesignal_tag_hash = hashlib.sha256(tag_input).hexdigest()

print(f'{notification_key}:{onesignal_tag_hash}')
")

NOTIFICATION_KEY=$(echo "$HASHES" | cut -d':' -f1)
ONESIGNAL_TAG_HASH=$(echo "$HASHES" | cut -d':' -f2)

# CREATE UNIQUE MULTI-TENANT PYTHON HANDLER DESTINATION
INTEGRATION_SCRIPT="/var/ossec/integrations/custom-synklav-${NODE_UID}"
echo "[STATUS] Writing localized script handler instance -> $INTEGRATION_SCRIPT"

cat << 'EOF' > $INTEGRATION_SCRIPT
#!/usr/bin/python3
import sys
import json
import http.client
import urllib.parse
import hmac
import hashlib
import time

alert_file = sys.argv[1]

with open(alert_file, 'r') as f:
    alert_json = f.read()

NODE_UID = "${NODE_UID}"
WORKER_URL = "${WORKER_URL}"
NOTIFICATION_KEY = "${NOTIFICATION_KEY}"
TAG_HASH = "${ONE_SIGNAL_TAG_HASH}"
TG_CHAT_ID = "${TG_CHAT_ID}"
CUSTOM_APP_ID = "${CUSTOM_APP_ID}"
CUSTOM_REST_KEY = "${CUSTOM_REST_KEY}"

parsed_url = urllib.parse.urlparse(WORKER_URL)
host = parsed_url.netloc
path = parsed_url.path if parsed_url.path else "/"

timestamp = str(int(time.time()))

message = (alert_json + timestamp + NODE_UID).encode('utf-8')
signature = hmac.new(bytes.fromhex(NOTIFICATION_KEY), message, hashlib.sha256).hexdigest()

headers = {
    "Content-Type": "application/json",
    "X-Synklav-Signature": signature,
    "X-Synklav-Timestamp": timestamp,
    "X-Synklav-Node-UID": NODE_UID,
    "X-Synklav-Notification-Key": NOTIFICATION_KEY,
    "X-Synklav-Tag-Hash": TAG_HASH,
    "X-Synklav-Telegram-Chat-ID": TG_CHAT_ID if TG_CHAT_ID else "null",
    "X-Synklav-Custom-App-ID": CUSTOM_APP_ID if CUSTOM_APP_ID else "null",
    "X-Synklav-Custom-REST-Key": CUSTOM_REST_KEY if CUSTOM_REST_KEY else "null"
}

try:
    conn = http.client.HTTPSConnection(host, timeout=10)
    conn.request("POST", path, body=alert_json, headers=headers)
    response = conn.getresponse()
    conn.close()
except Exception:
    sys.exit(0)
EOF

sed -i "s/\${NODE_UID}/$NODE_UID/g" $INTEGRATION_SCRIPT
sed -i "s|\${WORKER_URL}|$WORKER_URL|g" $INTEGRATION_SCRIPT
sed -i "s/\${NOTIFICATION_KEY}/$NOTIFICATION_KEY/g" $INTEGRATION_SCRIPT
sed -i "s/\${ONE_SIGNAL_TAG_HASH}/$ONE_SIGNAL_TAG_HASH/g" $INTEGRATION_SCRIPT
sed -i "s/\${TG_CHAT_ID}/$TG_CHAT_ID/g" $INTEGRATION_SCRIPT
sed -i "s/\${CUSTOM_APP_ID}/$CUSTOM_APP_ID/g" $INTEGRATION_SCRIPT
sed -i "s/\${CUSTOM_REST_KEY}/$CUSTOM_REST_KEY/g" $INTEGRATION_SCRIPT

chmod 750 $INTEGRATION_SCRIPT
chown root:wazuh $INTEGRATION_SCRIPT

# ------------------------------------------------------------------------------
# CONFIGURATION INJECTION AND MULTI-TENANT HANDLING
# ------------------------------------------------------------------------------
echo "[STATUS] Updating structural layout rules -> $OSSEC_CONF"
cp $OSSEC_CONF "${OSSEC_CONF}.bak"

# Define the isolated payload snippet for this specific tenant configuration entry
NEW_XML_BLOCK="  <integration>\n    <name>custom-synklav-${NODE_UID}</name>\n    <level>1</level>\n    <alert_format>json</alert_format>\n  </integration>"

if [ "$EXEC_PROFILE" == "1" ]; then
  # INITIALIZE MODE: Pure initialization block setup including wrappers
  if grep -q "" "$OSSEC_CONF"; then
    echo "[ERROR] System already initialized. Use profile 2 (UPDATE) to register additional users."
    exit 1
  fi
  
  cat << EOF > /tmp/synklav_append.xml
<integration>
    <name>custom-synklav-${NODE_UID}</name>
    <level>1</level>
    <alert_format>json</alert_format>
  </integration>
EOF
  sed -i '/<\/ossec_config>/e cat /tmp/synklav_append.xml' $OSSEC_CONF
  rm /tmp/synklav_append.xml

elif [ "$EXEC_PROFILE" == "2" ]; then
  # UPDATE MODE: Safely append new tenant blocks inside the core wrapper zone
  if ! grep -q "" "$OSSEC_CONF"; then
    echo "[ERROR] Synklav core missing from ossec.conf. Run profile 1 (INITIALIZE) first."
    exit 1
  fi
  
  # Prevent duplicated configuration bindings for identical keys
  if grep -q "custom-synklav-${NODE_UID}" "$OSSEC_CONF"; then
    echo "[WARNING] Configuration mapping for node $NODE_UID already exists. Refreshing script file only."
  else
    # Append code block systematically directly above the closing tag block identifier anchor
    sed -i "//i $NEW_XML_BLOCK" $OSSEC_CONF
  fi
fi

# 5. REBOOT WAHAZH PROCESSCORE
echo "[STATUS] Hot-rebooting Wazuh engine process core..."
/var/ossec/bin/wazuh-control restart

echo "===================================================="
echo " SYSTEM CONFIGURATION PASS VERIFIED                 "
echo "===================================================="
echo "⚠️  METRIC SUMMARY FOR APPLICATION PROVISIONING:"
echo "👉 Node UID: $NODE_UID"
echo "👉 OneSignal Tag Hash: $ONESIGNAL_TAG_HASH"
echo "👉 Notification Key: $NOTIFICATION_KEY"
echo "===================================================="
