#!/bin/bash

# ==============================================================================
# SYNKLAV - AUTOMATED WAZUH INTEGRATION SETUP SCRIPT (ZERO-TRUST ARCHITECTURE)
# ==============================================================================

# Enforce root execution
if [ "$EUID" -ne 0 ]; then
  echo "🚨 Error: This script must be run as root (sudo)."
  exit 1
fi

echo "===================================================="
echo "🚀 Initializing Synklav Hub Integration Deployment"
echo "===================================================="

# 1. USER INPUT GATHERING
read -p "➔ Enter the UNIQUE NODE UID for this server: " NODE_UID
NODE_UID=$(echo "$NODE_UID" | tr -d '[:space:]')

read -p "➔ Enter your 24-word Recovery Kit (single line, space-separated): " RECOVERY_KIT
RECOVERY_KIT=$(echo "$RECOVERY_KIT" | tr -s ' ' | tr '[:upper:]' '[:lower:]')

WORD_COUNT=$(echo "$RECOVERY_KIT" | wc -w)
if [ "$WORD_COUNT" -ne 24 ]; then
  echo "🚨 Error: The Recovery Kit must contain exactly 24 words. Detected: $WORD_COUNT"
  exit 1
fi

read -p "➔ Enter your Cloudflare Worker Target URL: " WORKER_URL
WORKER_URL=$(echo "$WORKER_URL" | tr -d '[:space:]')

read -p "➔ Do you want to route alerts to a Telegram Channel? (yes/no): " IS_TELEGRAM
TG_CHAT_ID="null"

if [[ "$IS_TELEGRAM" =~ ^([yY][eE][sS]|[yY])$ ]]; then
  read -p "   - Enter your Telegram Chat ID: " TG_CHAT_ID
  TG_CHAT_ID=$(echo "$TG_CHAT_ID" | tr -d '[:space:]')
fi

if [ -z "$NODE_UID" ] || [ -z "$WORKER_URL" ]; then
    echo "❌ Error: Node UID and Cloudflare Worker URL are mandatory fields."
    exit 1
fi

echo "⏳ Computing symmetric cryptographic key derivations via BIP39 standard..."

# 2. CRYPTOGRAPHIC DERIVATION (MATCHING FLUTTERFLOW DART VAULT MATRICES)
HASHES=$(python3 -c "
import hashlib
import binascii

# BIP39 standard PBKDF2 parameters (512-bit seed, 2048 iterations, HMAC-SHA512)
mnemonic_text = '$RECOVERY_KIT'.strip().encode('utf-8')
salt = b'mnemonic'

full_seed = hashlib.pbkdf2_hmac('sha512', mnemonic_text, salt, 2048, 64)

# Extract first 32 bytes identical to Dart's sublist(0, 32)
master_key_bytes = full_seed[0:32]
master_key_hex = binascii.hexlify(master_key_bytes).decode('utf-8')

# One-way isolated deterministic key chain mapping
node_uid = '$NODE_UID'
notification_key_input = (node_uid + master_key_hex).encode('utf-8')
notification_key = hashlib.sha256(notification_key_input).hexdigest()

tag_input = (notification_key + node_uid).encode('utf-8')
onesignal_tag_hash = hashlib.sha256(tag_input).hexdigest()

print(f'{notification_key}:{onesignal_tag_hash}')
")

NOTIFICATION_KEY=$(echo "$HASHES" | cut -d':' -f1)
ONESIGNAL_TAG_HASH=$(echo "$HASHES" | cut -d':' -f2)

# 3. CREATING NATIVE EXECUTABLE WAZUH INTEGRATION SCRIPT
INTEGRATION_SCRIPT="/var/ossec/integrations/custom-synklav"
echo "💾 Writing executable integration handler to $INTEGRATION_SCRIPT..."

cat << 'EOF' > $INTEGRATION_SCRIPT
#!/usr/bin/python3
import sys
import json
import http.client
import urllib.parse
import hmac
import hashlib
import time

# Capture arguments passed natively by the Wazuh manager core
alert_file = sys.argv[1]

with open(alert_file, 'r') as f:
    alert_json = f.read()

# INJECTED EMBEDDED IDENTIFIERS
NODE_UID = "${NODE_UID}"
WORKER_URL = "${WORKER_URL}"
NOTIFICATION_KEY = "${NOTIFICATION_KEY}"
TAG_HASH = "${ONE_SIGNAL_TAG_HASH}"
TG_CHAT_ID = "${TG_CHAT_ID}"

# Parse Cloudflare Worker URL components
parsed_url = urllib.parse.urlparse(WORKER_URL)
host = parsed_url.netloc
path = parsed_url.path if parsed_url.path else "/"

# Cryptographic anti-replay validation timestamp window anchor
timestamp = str(int(time.time()))

# Calculate HMAC-SHA256 signature payload integrity verification block
message = (alert_json + timestamp + NODE_UID).encode('utf-8')
signature = hmac.new(bytes.fromhex(NOTIFICATION_KEY), message, hashlib.sha256).hexdigest()

# Build rigid Zero-Trust network transport request headers
headers = {
    "Content-Type": "application/json",
    "X-Synklav-Signature": signature,
    "X-Synklav-Timestamp": timestamp,
    "X-Synklav-Node-UID": NODE_UID,
    "X-Synklav-Notification-Key": NOTIFICATION_KEY,
    "X-Synklav-Tag-Hash": TAG_HASH,
    "X-Synklav-Telegram-Chat-ID": TG_CHAT_ID if TG_CHAT_ID else "null"
}

# Atomic HTTP POST dispatches directly towards the edge network proxy pipeline
try:
    conn = http.client.HTTPSConnection(host, timeout=10)
    conn.request("POST", path, body=alert_json, headers=headers)
    response = conn.getresponse()
    conn.close()
except Exception:
    sys.exit(0)
EOF

# Replace installation keys cleanly into the generated python binary script
sed -i "s/\${NODE_UID}/$NODE_UID/g" $INTEGRATION_SCRIPT
sed -i "s|\${WORKER_URL}|$WORKER_URL|g" $INTEGRATION_SCRIPT
sed -i "s/\${NOTIFICATION_KEY}/$NOTIFICATION_KEY/g" $INTEGRATION_SCRIPT
sed -i "s/\${ONE_SIGNAL_TAG_HASH}/$ONE_SIGNAL_TAG_HASH/g" $INTEGRATION_SCRIPT
sed -i "s/\${TG_CHAT_ID}/$TG_CHAT_ID/g" $INTEGRATION_SCRIPT

# Assign strict Wazuh execution security permissions
chmod 750 $INTEGRATION_SCRIPT
chown root:wazuh $INTEGRATION_SCRIPT

# 4. OSSEC.CONF NATIVE AUTOMATED PATTERN INJECTION
OSSEC_CONF="/var/ossec/etc/ossec.conf"
echo "⚙️ Injecting dynamic routing configuration block into $OSSEC_CONF..."

# Preventive backup snapshot commit
cp $OSSEC_CONF "${OSSEC_CONF}.bak"

# Append integration blocks seamlessly inside configuration mapping files
cat << EOF > /tmp/synklav_block.xml
  <integration>
    <name>custom-synklav</name>
    <level>1</level> 
    <alert_format>json</alert_format>
  </integration>
EOF

# Inject integration snippet before configuration layout boundary closes
sed -i '/<\/ossec_config>/e cat /tmp/synklav_block.xml' $OSSEC_CONF
rm /tmp/synklav_block.xml

# 5. RESTART LOCAL WAZUH CORE SERVICES
echo "🔄 Restarting Wazuh Manager engine instance..."
/var/ossec/bin/wazuh-control restart

echo "===================================================="
echo "✅ DEPLOYMENT COMPLETED SUCCESSFULLY"
echo "===================================================="
echo "⚠️  REGISTRATION SUMMARY (GIVE THESE TO THE USER):"
echo "👉 Node UID: $NODE_UID"
echo "👉 OneSignal Tag Hash: $ONE_SIGNAL_TAG_HASH"
echo "👉 Notification Key: $NOTIFICATION_KEY"
echo "===================================================="
