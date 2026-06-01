#!/usr/bin/env python3
import os
import sys
import hashlib
import binascii
import urllib.parse
import time
import glob
import shutil
import subprocess
import re
import atexit
from datetime import datetime

print("====================================================")
print(" SYNKLAV HUB SYSTEM INTEGRATION ENGINE (FCM) v4.0   ")
print("====================================================")

OSSEC_CONF = "/var/ossec/etc/ossec.conf"
WORKER_URL = "https://synklav-notification-hub.synklav.workers.dev/"
LOCK_FILE = "/tmp/synklav_installer.lock"

# ------------------------------------------------------------------------------
# SEGURIDAD DE HILOS (LOCKING) Y PRIVILEGIOS
# ------------------------------------------------------------------------------
if os.getuid() != 0:
    print("[CRITICAL] Script must be run as root (sudo).")
    sys.exit(1)

if os.path.exists(LOCK_FILE):
    print("[CRITICAL] Another instance of the Synklav installer is currently running.")
    sys.exit(1)

try:
    with open(LOCK_FILE, 'w') as f: f.write(str(os.getpid()))
except IOError:
    print("[CRITICAL] Failed to acquire execution lock.")
    sys.exit(1)

def cleanup_lock():
    if os.path.exists(LOCK_FILE): os.remove(LOCK_FILE)
atexit.register(cleanup_lock)

# ------------------------------------------------------------------------------
# MENÚ Y SELECCIÓN DE PERFIL
# ------------------------------------------------------------------------------
print("Select execution profile:")
print(" 1) INITIALIZE      : Fresh deployment of Synklav core container.")
print(" 2) ADD USER        : Append a new user profile / node UID.")
print(" 3) UPDATE TELEGRAM : Change the minimum alert level for Telegram routing.")
print(" 4) REMOVE USER     : Delete a single specific user profile cleanly.")
print(" 5) PURGE ALL       : Complete atomic removal of all Synklav structures.")

try:
    exec_profile = int(input("➔ Enter profile selection (1-5): ").strip())
except ValueError:
    print("[CRITICAL] Invalid selection.")
    sys.exit(1)

if exec_profile not in [1, 2, 3, 4, 5]:
    print("[CRITICAL] Out of bounds profile selection.")
    sys.exit(1)

if not os.path.exists(OSSEC_CONF):
    print(f"[CRITICAL] {OSSEC_CONF} not found.")
    sys.exit(1)

# ------------------------------------------------------------------------------
# BACKUP CON VERSIONADO Y BLOQUEO CRÍTICO
# ------------------------------------------------------------------------------
ts = datetime.now().strftime("%Y%m%d%H%M%S")
backup_path = f"{OSSEC_CONF}.{ts}.bak"
try:
    shutil.copyfile(OSSEC_CONF, backup_path)
    print(f"[STATUS] OSSEC Backup secured at: {backup_path}")
except Exception as e:
    print(f"[CRITICAL] Aborting. Failed to create configuration backup: {e}")
    sys.exit(1)

# ------------------------------------------------------------------------------
# VALIDACIÓN ESTRICTA DE INPUTS (Prevención de Path Traversal)
# ------------------------------------------------------------------------------
node_uid = ""
recovery_kit = ""
tg_chat_id = "null"
tg_min_level = "1"

def validate_node_uid(uid):
    if not re.match(r'^[a-zA-Z0-9]+$', uid):
        print("[CRITICAL] Invalid Node UID. Only alphanumeric characters allowed.")
        sys.exit(1)
    return uid

def validate_tg_level(level):
    if not level.isdigit() or not (1 <= int(level) <= 15):
        print("[CRITICAL] Telegram Minimum Level must be an integer between 1 and 15.")
        sys.exit(1)
    return level

if exec_profile in [1, 2]:
    node_uid = validate_node_uid(input("➔ Enter target UNIQUE NODE UID: ").strip())
    
    raw_kit = input("➔ Enter your 24-word Recovery Kit (single line): ").strip().lower()
    recovery_kit = " ".join(raw_kit.split())
    if len(recovery_kit.split()) != 24:
        print("[CRITICAL] Recovery Kit must be exactly 24 words.")
        sys.exit(1)
    
    if input("➔ Active secondary Telegram notification routing? (yes/no): ").strip().lower() in ['yes', 'y']:
        tg_chat_id = input("   - Target Chat ID string: ").strip()
        tg_min_level = validate_tg_level(input("   - Enter MINIMUM alert level for Telegram (1-15): ").strip())

elif exec_profile in [3, 4]:
    node_uid = validate_node_uid(input("➔ Enter target UNIQUE NODE UID: ").strip())
    if exec_profile == 3:
        tg_min_level = validate_tg_level(input("➔ Enter the NEW minimum alert level for Telegram (1-15): ").strip())

notification_key, tag_hash = "null", "null"
if exec_profile in [1, 2]:
    full_seed = hashlib.pbkdf2_hmac('sha512', recovery_kit.encode('utf-8'), b'mnemonic', 2048, 64)
    master_key_hex = binascii.hexlify(full_seed[0:32]).decode('utf-8')
    notification_key = hashlib.sha256((node_uid + master_key_hex).encode('utf-8')).hexdigest()
    tag_hash = hashlib.sha256((notification_key + node_uid).encode('utf-8')).hexdigest()

target_name = f"custom-synklav-{node_uid}"

# ------------------------------------------------------------------------------
# EXTRACCIÓN Y LIMPIEZA DEL XML
# ------------------------------------------------------------------------------
with open(OSSEC_CONF, 'r', encoding='utf-8') as f:
    raw_lines = f.read().splitlines()

clean_lines = []
in_integration = False
integration_buffer = []
is_synklav_integration = False

for line in raw_lines:
    if "SYNKLAV_START" in line or "SYNKLAV_END" in line: continue
    if re.search(r'<\s*integration\s*>', line):
        in_integration = True
        integration_buffer = [line]
        is_synklav_integration = False
        continue
    
    if in_integration:
        integration_buffer.append(line)
        if exec_profile == 5 and "custom-synklav" in line: is_synklav_integration = True
        elif exec_profile == 4 and target_name in line: is_synklav_integration = True
        
        if re.search(r'<\s*/\s*integration\s*>', line):
            in_integration = False
            if not is_synklav_integration: clean_lines.extend(integration_buffer)
            integration_buffer = []
        continue
    clean_lines.append(line)

# ------------------------------------------------------------------------------
# INYECCIÓN EN OSSEC.CONF Y ESCRITURA ATÓMICA
# ------------------------------------------------------------------------------
if exec_profile in [1, 2]:
    if exec_profile == 1 and any("custom-synklav" in l for l in clean_lines):
        print("[CRITICAL] System already initialized. Use profile 2 (ADD USER).")
        sys.exit(1)
    
    if exec_profile == 2 and any(target_name in l for l in clean_lines):
        print(f"[WARNING] Node {node_uid} already exists. Overwriting script only.")
    else:
        idx = -1
        for i, l in enumerate(clean_lines):
            if re.search(r'<\s*/\s*ossec_config\s*>', l): idx = i
        if idx == -1:
            print("[CRITICAL] Malformed ossec.conf: </ossec_config> tag missing.")
            sys.exit(1)
        
        new_block = ["  <integration>", f"    <name>{target_name}</name>", "    <level>3</level>", "    <alert_format>json</alert_format>", "  </integration>"]
        clean_lines = clean_lines[:idx] + new_block + clean_lines[idx:]

final_content = "\n".join(clean_lines) + "\n"
tmp_path = OSSEC_CONF + ".tmp"
with open(tmp_path, 'w', encoding='utf-8') as f: f.write(final_content)
os.replace(tmp_path, OSSEC_CONF)

# ------------------------------------------------------------------------------
# ELIMINACIÓN DE SCRIPTS CON BACKUP EN RAM PARA ROLLBACK TOTAL
# ------------------------------------------------------------------------------
deleted_scripts_backup = {}
if exec_profile in [4, 5]:
    files_to_delete = []
    if exec_profile == 5:
        for f_path in glob.glob('/var/ossec/integrations/custom-synklav-*'):
            if re.match(r'^/var/ossec/integrations/custom-synklav-[a-zA-Z0-9]+$', f_path):
                files_to_delete.append(f_path)
    elif exec_profile == 4:
        target_file = f"/var/ossec/integrations/{target_name}"
        if os.path.exists(target_file): files_to_delete.append(target_file)

    for f_path in files_to_delete:
        try:
            with open(f_path, 'rb') as f:
                deleted_scripts_backup[f_path] = f.read()
            os.remove(f_path)
        except Exception as e:
            print(f"[WARNING] Failed to remove {f_path}: {e}")

# ------------------------------------------------------------------------------
# SCRIPT PYTHON DISPARADOR (Extracción Robusta)
# ------------------------------------------------------------------------------
def safe_extract(pattern, text, default=None):
    match = re.search(pattern, text)
    return match.group(1) if match else default

if exec_profile in [1, 2, 3]:
    if exec_profile == 3:
        sp = f"/var/ossec/integrations/{target_name}"
        if not os.path.exists(sp): 
            print("[CRITICAL] Node integration file not found for update.")
            sys.exit(1)
        with open(sp, 'r') as sf: old_script = sf.read()
        
        node_uid = safe_extract(r'NODE_UID\s*=\s*"([^"]+)"', old_script)
        notification_key = safe_extract(r'NOTIFICATION_KEY\s*=\s*"([^"]+)"', old_script)
        tag_hash = safe_extract(r'TAG_HASH\s*=\s*"([^"]+)"', old_script)
        tg_chat_id = safe_extract(r'TG_CHAT_ID\s*=\s*"([^"]+)"', old_script, "null")
        
        if not all([node_uid, notification_key, tag_hash]):
            print("[CRITICAL] Integration script is corrupted or manually modified. Cannot update.")
            sys.exit(1)

    script_code = f"""#!/usr/bin/python3
import sys, json, http.client, urllib.parse, hmac, hashlib, time
with open(sys.argv[1], 'r') as f: alert_json = f.read()
NODE_UID, NOTIFICATION_KEY, TAG_HASH = "{node_uid}", "{notification_key}", "{tag_hash}"
TG_CHAT_ID, TG_MIN_LEVEL = "{tg_chat_id}", "{tg_min_level}"
parsed = urllib.parse.urlparse("{WORKER_URL}")
ts = str(int(time.time()))
sig = hmac.new(bytes.fromhex(NOTIFICATION_KEY), (alert_json + ts + NODE_UID).encode('utf-8'), hashlib.sha256).hexdigest()
headers = {{
    "Content-Type": "application/json", 
    "X-Synklav-Signature": sig, 
    "X-Synklav-Timestamp": ts, 
    "X-Synklav-Node-UID": NODE_UID, 
    "X-Synklav-Notification-Key": NOTIFICATION_KEY, 
    "X-Synklav-Tag-Hash": TAG_HASH, 
    "X-Synklav-Telegram-Chat-ID": TG_CHAT_ID,
    "X-Synklav-Telegram-Min-Level": TG_MIN_LEVEL
}}
try:
    conn = http.client.HTTPSConnection(parsed.netloc, timeout=10)
    conn.request("POST", parsed.path if parsed.path else "/", body=alert_json, headers=headers)
    conn.getresponse()
    conn.close()
except: sys.exit(0)
"""
    sp = f"/var/ossec/integrations/{target_name}"
    with open(sp, 'w', encoding='utf-8') as sf: sf.write(script_code)
    os.chmod(sp, 0o750)
    try:
        import pwd, grp
        os.chown(sp, pwd.getpwnam('root').pw_uid, grp.getgrnam('wazuh').gr_gid)
    except Exception as e:
        print(f"[WARNING] Ownership change failed: {e}")

# ------------------------------------------------------------------------------
# REINICIO Y PROTECCIÓN DE ROLLBACK TOTAL
# ------------------------------------------------------------------------------
print("[STATUS] Hot-rebooting Wazuh engine process core...")
restart_result = subprocess.run(["/var/ossec/bin/wazuh-control", "restart"], capture_output=True, text=True)

if restart_result.returncode != 0:
    print("[CRITICAL] Wazuh core failed to restart. The ossec.conf might be corrupted.")
    print(restart_result.stderr)
    print(f"[STATUS] INITIATING AUTOMATIC TOTAL ROLLBACK to {backup_path}...")
    
    # 1. Restaura la configuración XML
    shutil.copyfile(backup_path, OSSEC_CONF)
    
    # 2. Restaura los scripts eliminados desde la RAM
    for f_path, content in deleted_scripts_backup.items():
        with open(f_path, 'wb') as f:
            f.write(content)
        os.chmod(f_path, 0o750)
    
    # 3. Limpia el rastro de la integración fallida si intentábamos instalar
    if exec_profile in [1, 2]:
        try: os.remove(f"/var/ossec/integrations/{target_name}")
        except: pass

    rollback_result = subprocess.run(["/var/ossec/bin/wazuh-control", "restart"], capture_output=True, text=True)
    if rollback_result.returncode == 0:
        print("[STATUS] Rollback successful. Server is safely running the previous configuration.")
    else:
        print("[CRITICAL] Rollback failed. Manual intervention required.")
    sys.exit(1)

print("====================================================")
print(" ✅ OPERATION VERIFIED AND ACTIVE")
print("====================================================")
