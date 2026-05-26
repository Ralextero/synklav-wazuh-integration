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
echo " 1) INITIALIZE      : Fresh deployment of Synklav core container."
echo " 2) ADD USER        : Append a new multi-tenant user profile / node UID."
echo " 3) UPDATE TELEGRAM : Change the minimum alert level for an existing node."
echo " 4) REMOVE USER     : Delete a single specific user profile cleanly."
echo " 5) PURGE ALL       : Complete atomic removal of all Synklav structures."
read -p "➔ Enter profile selection (1-5): " EXEC_PROFILE

# TIMESTAMPED BACKUP ROUTINE FOR ANTI-DATA-LOSS
TIMESTAMP=$(date +%Y%m%d%H%M%S)
BACKUP_CONF="${OSSEC_CONF}.${TIMESTAMP}.bak"

# ------------------------------------------------------------------------------
# PROFILE 5: PURGE ALL OPERATIONS (ATOMIC REWRITE VECTOR - IMMUNE TO EMPTY FILES)
# ------------------------------------------------------------------------------
if [ "$EXEC_PROFILE" == "5" ]; then
  echo "[WARNING] Initializing complete system purge of Synklav assets..."
  cp "$OSSEC_CONF" "$BACKUP_CONF"
  cp "$OSSEC_CONF" "${OSSEC_CONF}.bak"
  
  # Remove physical integration files from disk securely
  python3 -c "
import os
int_dir = '/var/ossec/integrations/'
if os.path.exists(int_dir):
    for f in os.listdir(int_dir):
        if f.startswith('custom-synklav'):
            try:
                os.remove(os.path.join(int_dir, f))
            except Exception:
                pass
"

  # Safe Structural Clean Up using Atomic Temp Write Protection
  python3 -c "
import os
import sys

conf_path = '$OSSEC_CONF'
tmp_path = conf_path + '.tmp'

with open(conf_path, 'r') as f:
    content = f.read()

# 1. Strip anchored segments
if '' in content:
    try:
        parts = content.split('')
        sub_parts = parts[1].split('')
        content = parts[0] + sub_parts[1]
    except Exception:
        pass

# 2. Extract loose unanchored integration matrices
lines = content.splitlines()
new_lines = []
block_buffer = []
inside_integration = False
has_synklav = False

for line in lines:
    if '<integration>' in line:
        inside_integration = True
        block_buffer = [line]
        has_synklav = False
        continue
        
    if inside_integration:
        block_buffer.append(line)
        if 'custom-synklav' in line:
            has_synklav = True
        if '</integration>' in line:
            if not has_synklav:
                new_lines.extend(block_buffer)
            inside_integration = False
            block_buffer = []
        continue
        
    new_lines.append(line)

final_output = []
for l in new_lines:
    if '' in l or '' in l:
        continue
    final_output.append(l)

final_string = '\n'.join(final_output) + '\n'

# SANITY CHECK: Anti-corruption defensive wall (Never write empty payloads)
if len(final_string).strip() < 200 or '<ossec_config>' not in final_string:
    print('[CRITICAL ERROR] Purge process structural anomaly detected. Aborting configuration write to save ossec.conf.')
    sys.exit(1)

# Atomic file commit
with open(tmp_path, 'w') as f:
    f.write(final_string)

os.replace(tmp_path, conf_path)
print('[SUCCESS]')
" || exit 1

  echo "[STATUS] All configuration boundaries and custom nodes evicted smoothly."
  echo "[STATUS] Hot-rebooting Wazuh engine process core..."
  /var/ossec/bin/wazuh-control restart
  echo "===================================================="
  echo " 🔥 PURGE OPERATION COMPLETE: SYSTEM RESTORED CLEANLY"
  echo "===================================================="
  exit 0
fi

# ------------------------------------------------------------------------------
# PROFILE 4: REMOVE SINGLE USER PROFILE (ATOMIC SAFETY ENGINE)
# ------------------------------------------------------------------------------
if [ "$EXEC_PROFILE" == "4" ]; then
  read -p "➔ Enter the specific NODE UID to remove: " TARGET_UID
  TARGET_UID=$(echo "$TARGET_UID" | tr -d '[:space:]')
  
  if [ -z "$TARGET_UID" ]; then
    echo "[ERROR] Node UID cannot be empty."
    exit 1
  fi

  echo "[STATUS] Initiating targeted removal for node: $TARGET_UID"
  cp "$OSSEC_CONF" "$BACKUP_CONF"

  rm -f "/var/ossec/integrations/custom-synklav-${TARGET_UID}"

  python3 -c "
import os
import sys

conf_path = '$OSSEC_CONF'
tmp_path = conf_path + '.tmp'
target_name = 'custom-synklav-$TARGET_UID'

with open(conf_path, 'r') as f:
    lines = f.readlines()

new_lines = []
inside_target = False
block_buffer = []

for line in lines:
    if '<integration>' in line:
        inside_target = False
        block_buffer = [line]
        continue
    
    if len(block_buffer) > 0:
        block_buffer.append(line)
        if f'<name>{target_name}</name>' in line:
            inside_target = True
        if '</integration>' in line:
            if not inside_target:
                new_lines.extend(block_buffer)
            block_buffer = []
        continue
        
    new_lines.append(line)

final_string = ''.join(new_lines)

# Sanity enforcement check
if len(final_string).strip() < 200 or '<ossec_config>' not in final_string:
    print('[CRITICAL ERROR] Anomaly caught during execution block filtering. Target write aborted.')
    sys.exit(1)

with open(tmp_path, 'w') as f:
    f.write(final_string)

os.replace(tmp_path, conf_path)
" || exit 1

  echo "[STATUS] Custom node block matching $TARGET_UID evicted from configuration."
  /var/ossec/bin/wazuh-control restart
  exit 0
fi

# ------------------------------------------------------------------------------
# PROFILE 3: UPDATE TELEGRAM ALERT LEVEL IN PLACE (ATOMIC SAFETY ENGINE)
# ------------------------------------------------------------------------------
if [ "$EXEC_PROFILE" == "3" ]; then
  read -p "➔ Enter the target NODE UID to update: " TARGET_UID
  TARGET_UID=$(echo "$TARGET_UID" | tr -d '[:space:]')
  read -p "➔ Enter the NEW minimum alert level for Telegram (1-15): " NEW_LVL
  NEW_LVL=$(echo "$NEW_LVL" | tr -d '[:space:]')

  if [ -z "$TARGET_UID" ] || [ -z "$NEW_LVL" ]; then
    echo "[ERROR] Inputs cannot be null."
    exit 1
  fi

  echo "[STATUS] Modifying Telegram alert execution thresholds to level $NEW_LVL..."
  cp "$OSSEC_CONF" "$BACKUP_CONF"

  python3 -c "
import os
import sys

conf_path = '$OSSEC_CONF'
tmp_path = conf_path + '.tmp'
target_name = 'custom-synklav-$TARGET_UID'
new_level = '$NEW_LVL'

with open(conf_path, 'r') as f:
    lines = f.readlines()

new_lines = []
inside_target = False
for line in lines:
    if '<integration>' in line:
        inside_target = False
    if 'custom-synklav-' in line and f'{target_name}' in line:
        inside_target = True
    if inside_target and '<level>' in line:
        line = f'    <level>{new_level}</level>\n'
    new_lines.append(line)

final_string = ''.join(new_lines)

if len(final_string).strip() < 200 or '<ossec_config>' not in final_string:
    sys.exit(1)

with open(tmp_path, 'w') as f:
    f.write(final_string)

os.replace(tmp_path, conf_path)
" || exit 1

  /var/ossec/bin/wazuh-control restart
  exit 0
fi

# ------------------------------------------------------------------------------
# PROFILES 1 & 2: DATA ACQUISITION & FRESH DEPLOYMENTS
# ------------------------------------------------------------------------------
if [ "$EXEC_PROFILE" != "1" ] && [ "$EXEC_PROFILE" != "2" ]; then
  echo "[ERROR] Invalid selection matrix context."
  exit 1
fi

read -p "➔ Enter target UNIQUE NODE UID: " NODE_UID
NODE_UID=$(echo "$NODE_UID" | tr -d '[:space:]')

read -p "➔ Enter your 24-word Recovery Kit (single line): " RECOVERY_KIT
RECOVERY_KIT=$(echo "$RECOVERY_KIT" | tr -s ' ' | tr '[:upper:]' '[:lower:]')

WORD_COUNT=$(echo "$RECOVERY_KIT" | wc -w)
if [ "$WORD_COUNT" -ne 24 ]; then
  echo "[ERROR] Cryptographic validation failure: Mnemonic matrix must equal 24 elements."
  exit 1
fi

read -p "➔ Enter the MINIMUM alert level for Telegram/Push routing (1-15): " MIN_ALERT_LEVEL
MIN_ALERT_LEVEL=$(echo "$MIN_ALERT_LEVEL" | tr -d '[:space:]')

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

if [ -z "$NODE_UID" ] || [ -z "$MIN_ALERT_LEVEL" ]; then
    echo "[ERROR] Required initialization variable missing."
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
#!/usr/python3
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
cp $OSSEC_CONF "$BACKUP_CONF"

NEW_XML_BLOCK="  <integration>\n    <name>custom-synklav-${NODE_UID}</name>\n    <level>${MIN_ALERT_LEVEL}</level>\n    <alert_format>json</alert_format>\n  </integration>"

if [ "$EXEC_PROFILE" == "1" ]; then
  if grep -q "" "$OSSEC_CONF"; then
    echo "[ERROR] System already initialized. Use profile 2 (ADD USER) to register additional nodes."
    exit 1
  fi
  
  cat << EOF > /tmp/synklav_append.xml
<integration>
    <name>custom-synklav-${NODE_UID}</name>
    <level>${MIN_ALERT_LEVEL}</level>
    <alert_format>json</alert_format>
  </integration>
EOF
  sed -i '/<\/ossec_config>/e cat /tmp/synklav_append.xml' $OSSEC_CONF
  rm /tmp/synklav_append.xml

elif [ "$EXEC_PROFILE" == "2" ]; then
  if ! grep -q "" "$OSSEC_CONF"; then
    echo "[ERROR] Synklav core missing from ossec.conf. Run profile 1 (INITIALIZE) first."
    exit 1
  fi
  
  if grep -q "custom-synklav-${NODE_UID}" "$OSSEC_CONF"; then
    echo "[WARNING] Configuration mapping for node $NODE_UID already exists. Refreshing script file only."
  else
    sed -i "//i $NEW_XML_BLOCK" $OSSEC_CONF
  fi
fi

# 5. REBOOT WAZUH
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
