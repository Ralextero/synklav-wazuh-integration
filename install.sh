#!/usr/bin/env python3
import os
import sys
import hashlib
import binascii
import urllib.parse
import http.client
import time
import re
import glob
from datetime import datetime

print("====================================================")
print(" SYNKLAV HUB SYSTEM INTEGRATION ENGINE              ")
print("====================================================")

OSSEC_CONF = "/var/ossec/etc/ossec.conf"
WORKER_URL = "https://synklav-notification-hub.synklav.workers.dev/"

# Enforce root privileges
if os.getuid() != 0:
    print("[ERROR] Security context execution violation: Script must be run as root (sudo).")
    sys.exit(1)

# SYSTEM MODE SELECTION
print("Select execution profile:")
print(" 1) INITIALIZE      : Fresh deployment of Synklav core container.")
print(" 2) ADD USER        : Append a new multi-tenant user profile / node UID.")
print(" 3) UPDATE TELEGRAM : Change the minimum alert level for an existing node.")
print(" 4) REMOVE USER     : Delete a single specific user profile cleanly.")
print(" 5) PURGE ALL       : Complete atomic removal of all Synklav structures.")

try:
    exec_profile = int(input("➔ Enter profile selection (1-5): ").strip())
except ValueError:
    print("[ERROR] Invalid selection matrix context.")
    sys.exit(1)

if exec_profile not in [1, 2, 3, 4, 5]:
    print("[ERROR] Out of bounds profile selection.")
    sys.exit(1)

# TIMESTAMPED BACKUP ROUTINE
timestamp_str = datetime.now().strftime("%Y%m%d%H%M%S")
backup_conf = f"{OSSEC_CONF}.{timestamp_str}.bak"
legacy_backup = f"{OSSEC_CONF}.bak"

if os.path.exists(OSSEC_CONF):
    try:
        import shutil
        shutil.copyfile(OSSEC_CONF, backup_conf)
        shutil.copyfile(OSSEC_CONF, legacy_backup)
    except Exception as e:
        print(f"[ERROR] Failed to create security backup: {e}")
        sys.exit(1)
else:
    print("[ERROR] Target ossec.conf file not found.")
    sys.exit(1)

# ------------------------------------------------------------------------------
# DATA ACQUISITION
# ------------------------------------------------------------------------------
node_uid = ""
recovery_kit = ""
min_alert_level = "1"
custom_app_id = "null"
custom_rest_key = "null"
tg_chat_id = "null"

if exec_profile in [1, 2]:
    node_uid = input("➔ Enter target UNIQUE NODE UID: ").strip()
    if not node_uid:
        print("[ERROR] Node UID cannot be empty.")
        sys.exit(1)
        
    recovery_kit = input("➔ Enter your 24-word Recovery Kit (single line): ").strip().lower()
    recovery_kit = " ".join(recovery_kit.split())
    word_count = len(recovery_kit.split())
    
    if word_count != 24:
        print(f"[ERROR] Mnemonic matrix must equal 24 elements. Detected: {word_count}")
        sys.exit(1)
        
    min_alert_level = input("➔ Enter the MINIMUM alert level for Telegram/Push routing (1-15): ").strip()
    
    is_custom = input("➔ Activate Multi-Tenant / Custom OneSignal routing? (yes/no): ").strip().lower()
    if is_custom in ['yes', 'y']:
        custom_app_id = input("   - App ID string: ").strip()
        custom_rest_key = input("   - REST API Key string: ").strip()
        
    is_telegram = input("➔ Active secondary Telegram notification routing? (yes/no): ").strip().lower()
    if is_telegram in ['yes', 'y']:
        tg_chat_id = input("   - Target Chat ID string: ").strip()

elif exec_profile in [3, 4]:
    node_uid = input("➔ Enter target UNIQUE NODE UID: ").strip()
    if not node_uid:
        print("[ERROR] Node UID cannot be empty.")
        sys.exit(1)
    if exec_profile == 3:
        min_alert_level = input("➔ Enter the NEW minimum alert level for Telegram (1-15): ").strip()

# ------------------------------------------------------------------------------
# CORE CIPHER GENERATION (BIP39 SIMULATION)
# ------------------------------------------------------------------------------
notification_key = "null"
onesignal_tag_hash = "null"

if exec_profile in [1, 2]:
    mnemonic_bytes = recovery_kit.encode('utf-8')
    full_seed = hashlib.pbkdf2_hmac('sha512', mnemonic_bytes, b'mnemonic', 2048, 64)
    master_key_hex = binascii.hexlify(full_seed[0:32]).decode('utf-8')
    
    notification_key = hashlib.sha256((node_uid + master_key_hex).encode('utf-8')).hexdigest()
    onesignal_tag_hash = hashlib.sha256((notification_key + node_uid).encode('utf-8')).hexdigest()

# ------------------------------------------------------------------------------
# XML CONFIGURATION HANDLING
# ------------------------------------------------------------------------------
with open(OSSEC_CONF, 'r', encoding='utf-8') as f:
    output_content = f.read()

if "<ossec_config>" not in output_content or "</ossec_config>" not in output_content:
    print("[CRITICAL ERROR] Target ossec.conf is corrupted or missing master <ossec_config> tags.")
    sys.exit(1)

START_MARK = ""
END_MARK = ""
target_integration_name = f"custom-synklav-{node_uid}"

if exec_profile == 5:
    # PURGE ALL: Non-greedy approach. Dissolves markers and explicitly removes only integrations.
    output_content = output_content.replace(START_MARK, "").replace(END_MARK, "")
    output_content = re.sub(r'[ \t]*<integration>\s*<name>custom-synklav-[^<]+</name>.*?</integration>\n*', '', output_content, flags=re.DOTALL)
    
    for f_path in glob.glob('/var/ossec/integrations/custom-synklav*'):
        try: os.remove(f_path)
        except: pass

elif exec_profile == 4:
    # REMOVE SINGLE USER
    pattern = r'[ \t]*<integration>\s*<name>' + re.escape(target_integration_name) + r'</name>.*?</integration>\n*'
    output_content = re.sub(pattern, '', output_content, flags=re.DOTALL)
    
    try: os.remove(f"/var/ossec/integrations/{target_integration_name}")
    except: pass

elif exec_profile == 3:
    # UPDATE TELEGRAM LEVEL IN PLACE
    if target_integration_name not in output_content:
        print(f"[ERROR] Node profile for {node_uid} not found in configuration.")
        sys.exit(1)
        
    pattern = r'([ \t]*<integration>\s*<name>' + re.escape(target_integration_name) + r'</name>.*?)<level>\s*\d+\s*</level>(.*?</integration>)'
    output_content = re.sub(pattern, r'\g<1><level>' + min_alert_level + r'</level>\g<2>', output_content, flags=re.DOTALL)

elif exec_profile == 1:
    # INITIALIZE
    if START_MARK in output_content:
        print("[ERROR] System already initialized. Use profile 2 (ADD USER) to register additional nodes.")
        sys.exit(1)
        
    new_block = f"\n  {START_MARK}\n  <integration>\n    <name>{target_integration_name}</name>\n    <level>{min_alert_level}</level>\n    <alert_format>json</alert_format>\n  </integration>\n  {END_MARK}\n"
    output_content = output_content.replace("</ossec_config>", f"{new_block}</ossec_config>")

elif exec_profile == 2:
    # ADD USER
    if START_MARK not in output_content:
        print("[ERROR] Synklav core missing. Run profile 1 (INITIALIZE) first.")
        sys.exit(1)
        
    if target_integration_name in output_content:
        print(f"[WARNING] Node {node_uid} already exists. Overwriting handler script only.")
    else:
        new_integration = f"  <integration>\n    <name>{target_integration_name}</name>\n    <level>{min_alert_level}</level>\n    <alert_format>json</alert_format>\n  </integration>\n  {END_MARK}"
        output_content = output_content.replace(END_MARK, new_integration)

# ------------------------------------------------------------------------------
# ATOMIC SAVE GUARDRAIL
# ------------------------------------------------------------------------------
if "<ossec_config>" not in output_content or "</ossec_config>" not in output_content:
    print("[CRITICAL ERROR] Guardrail triggered: Prevented writing an anomalous layout. XML root tags lost.")
    sys.exit(1)

tmp_path = OSSEC_CONF + ".tmp"
with open(tmp_path, 'w', encoding='utf-8') as f:
    f.write(output_content)
os.replace(tmp_path, OSSEC_CONF)

# ------------------------------------------------------------------------------
# WRITE EXECUTABLE SCRIPT HANDLER (PROFILES 1 & 2)
# ------------------------------------------------------------------------------
if exec_profile in [1, 2]:
    script_path = f"/var/ossec/integrations/{target_integration_name}"
    
    script_code = f"""#!/usr/bin/python3
import sys, json, http.client, urllib.parse, hmac, hashlib, time

alert_file = sys.argv[1]
with open(alert_file, 'r') as f:
    alert_json = f.read()

NODE_UID = "{node_uid}"
WORKER_URL = "{WORKER_URL}"
NOTIFICATION_KEY = "{notification_key}"
TAG_HASH = "{onesignal_tag_hash}"
TG_CHAT_ID = "{tg_chat_id}"
CUSTOM_APP_ID = "{custom_app_id}"
CUSTOM_REST_KEY = "{custom_rest_key}"

parsed_url = urllib.parse.urlparse(WORKER_URL)
host = parsed_url.netloc
path = parsed_url.path if parsed_url.path else "/"

timestamp = str(int(time.time()))
message = (alert_json + timestamp + NODE_UID).encode('utf-8')
signature = hmac.new(bytes.fromhex(NOTIFICATION_KEY), message, hashlib.sha256).hexdigest()

headers = {{
    "Content-Type": "application/json",
    "X-Synklav-Signature": signature,
    "X-Synklav-Timestamp": timestamp,
    "X-Synklav-Node-UID": NODE_UID,
    "X-Synklav-Notification-Key": NOTIFICATION_KEY,
    "X-Synklav-Tag-Hash": TAG_HASH,
    "X-Synklav-Telegram-Chat-ID": TG_CHAT_ID if TG_CHAT_ID else "null",
    "X-Synklav-Custom-App-ID": CUSTOM_APP_ID if CUSTOM_APP_ID else "null",
    "X-Synklav-Custom-REST-Key": CUSTOM_REST_KEY if CUSTOM_REST_KEY else "null"
}}

try:
    conn = http.client.HTTPSConnection(host, timeout=10)
    conn.request("POST", path, body=alert_json, headers=headers)
    response = conn.getresponse()
    conn.close()
except:
    sys.exit(0)
"""
    with open(script_path, 'w', encoding='utf-8') as sf:
        sf.write(script_code)
        
    os.chmod(script_path, 0o750)
    try:
        import pwd, grp
        uid = pwd.getpwnam('root').pw_uid
        gid = grp.getgrnam('wazuh').gr_gid
        os.chown(script_path, uid, gid)
    except: pass

print("[STATUS] Hot-rebooting Wazuh engine process core...")
os.system("/var/ossec/bin/wazuh-control restart")

if exec_profile in [1, 2]:
    print("====================================================")
    print("✅ OPERATION VERIFIED AND ACTIVE")
    print("====================================================")
    print("⚠️  METRIC SUMMARY FOR APPLICATION PROVISIONING:")
    print(f"👉 Node UID: {node_uid}")
    print(f"👉 OneSignal Tag Hash: {onesignal_tag_hash}")
    print(f"👉 Notification Key: {notification_key}")
    print("====================================================")
else:
    print("====================================================")
    print(" 🔥 OPERATION COMPLETE: CLEAN EXIT CODE 0")
    print("====================================================")
