#!/usr/bin/env python3
# =============================================================================
#  SYNKLAV HUB SYSTEM INTEGRATION ENGINE (FCM) v6.0 (Production Release)
#  Wazuh -> Cloudflare Worker -> Firebase/Telegram push notification bridge
#
#  Architecture Decision Records (ADR):
#
#  [A1] restart_wazuh uses os.system() instead of subprocess.run():
#       Prevents hangs caused by Wazuh child daemons (wazuh-modulesd).
#  [A2] FCM Topic Hash calculation: sha256(notification_key + uid).
#       Matches Flutter client derivation symmetrically.
#  [A3] Integration script privileges: 0o750 root:wazuh_gid
#  [A4] .creds file privileges: 0o640 root:wazuh_gid
#  [A5] The integration script always exits with sys.exit(0) on any error.
#       Errors are safely written to sys.stderr for administrative debugging.
# =============================================================================

import os
import sys
import fcntl
import hashlib
import hmac
import urllib.parse
import glob
import shutil
import re
import atexit
import argparse
import json
from datetime import datetime

# =============================================================================
#  SYSTEM CONSTANTS
# =============================================================================
OSSEC_CONF       = "/var/ossec/etc/ossec.conf"
INTEGRATIONS_DIR = "/var/ossec/integrations"
WAZUH_CONTROL    = "/var/ossec/bin/wazuh-control"
WORKER_URL       = "https://synklav-notification-hub.synklav.workers.dev/"
LOCK_FILE        = "/tmp/synklav_installer.lock"
MIN_ALERT_LEVEL  = 3

BANNER = """\
====================================================
 SYNKLAV HUB SYSTEM INTEGRATION ENGINE (FCM) v6.0
===================================================="""

# =============================================================================
#  UTILITIES & LOCK MANAGEMENT
# =============================================================================
def log(msg: str) -> None:
    ts = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    print(f"[{ts}] {msg}")

def die(msg: str, code: int = 1) -> None:
    log(f"[CRITICAL] {msg}")
    sys.exit(code)

_lock_fd = None

def acquire_lock() -> None:
    global _lock_fd
    try:
        _lock_fd = open(LOCK_FILE, "w")
        fcntl.flock(_lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        _lock_fd.write(str(os.getpid()))
        _lock_fd.flush()
    except BlockingIOError:
        die("Another instance of the installer is running (active lock).")
    except OSError as exc:
        die(f"Failed to acquire execution lock: {exc}")
    atexit.register(release_lock)

def release_lock() -> None:
    global _lock_fd
    if _lock_fd is not None:
        try:
            fcntl.flock(_lock_fd, fcntl.LOCK_UN)
            _lock_fd.close()
        except OSError:
            pass
        try:
            os.unlink(LOCK_FILE)
        except OSError:
            pass
        _lock_fd = None

# =============================================================================
#  DYNAMIC WAZUH GROUP DETECTION
# =============================================================================
def get_wazuh_gid() -> int:
    import grp
    for group_name in ("wazuh", "ossec"):
        try:
            return grp.getgrnam(group_name).gr_gid
        except KeyError:
            continue
    die("Neither 'wazuh' nor 'ossec' group found. Is Wazuh properly installed?")

# =============================================================================
#  REGEX VALIDATORS
# =============================================================================
_RE_UID        = re.compile(r'^[a-zA-Z0-9_-]{1,64}$')
_RE_HEX        = re.compile(r'^[0-9a-fA-F]{64}$') 
_RE_TG_CHAT    = re.compile(r'^\s*null\s*$|^-?[0-9]{1,20}$')
_RE_INT_OPEN   = re.compile(r'^\s*<integration>\s*$')
_RE_INT_CLOSE  = re.compile(r'^\s*</integration>\s*$')
_RE_OSSEC_ROOT = re.compile(r'^\s*</ossec_config>\s*$')

def validate_node_uid(uid: str) -> str:
    if not uid or not _RE_UID.match(uid):
        die("Invalid UID. Only alphanumeric characters, hyphens, and underscores allowed.")
    return uid

def validate_notification_key(key: str) -> str:
    if not key:
        die("Notification Key is strictly required.")
    key = key.strip()
    if not _RE_HEX.match(key):
        die("Invalid Notification Key: must be exactly a 64-character hexadecimal string.")
    return key.lower()

def validate_tg_chat(chat_id: str) -> str:
    if not chat_id or chat_id == "null":
        return "null"
    chat_id = chat_id.strip()
    if not _RE_TG_CHAT.match(chat_id):
        die("Invalid Telegram Chat ID.")
    return chat_id

def validate_tg_level(level: str) -> str:
    lvl = (level or "").strip()
    if not lvl.isdigit() or not (1 <= int(lvl) <= 15):
        die("Minimum Telegram alert level must be an integer between 1 and 15.")
    return lvl

# =============================================================================
#  CREDENTIAL FILES MANAGEMENT
# =============================================================================
def creds_path(uid: str) -> str:
    return f"{INTEGRATIONS_DIR}/.synklav-{uid}.creds"

def write_creds(uid: str, data: dict) -> None:
    path = creds_path(uid)
    tmp  = path + ".tmp"
    wazuh_gid = get_wazuh_gid()
    try:
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(data, f)
        os.chmod(tmp, 0o640)
        try:
            os.chown(tmp, 0, wazuh_gid)
        except PermissionError:
            pass
        os.replace(tmp, path)
    except OSError as exc:
        try: os.unlink(tmp)
        except OSError: pass
        die(f"Failed to write credentials file: {exc}")

def read_creds(uid: str) -> dict:
    path = creds_path(uid)
    if not os.path.exists(path):
        die(f"Credentials not found for node '{uid}'.")
    try:
        with open(path, "r", encoding="utf-8") as f:
            return json.load(f)
    except (OSError, json.JSONDecodeError) as exc:
        die(f"Credentials file corrupted or unreadable: {exc}")

def delete_creds(uid: str) -> None:
    path = creds_path(uid)
    try:
        if os.path.exists(path):
            size = os.path.getsize(path)
            with open(path, "r+b") as f:
                f.write(b'\x00' * size)
                f.flush()
                os.fsync(f.fileno())
            os.unlink(path)
    except OSError:
        pass

# =============================================================================
#  OSSEC CONFIGURATION BACKUP
# =============================================================================
def make_backup() -> str:
    ts = datetime.now().strftime("%Y%m%d%H%M%S")
    backup = f"{OSSEC_CONF}.synklav-{ts}.bak"
    try:
        shutil.copyfile(OSSEC_CONF, backup)
        os.chmod(backup, 0o600)
        log(f"[STATUS] OSSEC configuration backup created at: {backup}")
        return backup
    except OSError as exc:
        die(f"Failed to create configuration backup: {exc}")

def purge_backups() -> None:
    for bak in glob.glob(f"{OSSEC_CONF}.synklav-*.bak"):
        try:
            os.unlink(bak)
            log(f"[STATUS] Backup removed: {bak}")
        except OSError:
            pass

# =============================================================================
#  INJECTOR SCRIPT (The Dummy Container)
# =============================================================================
def generate_integration_script(uid: str) -> str:
    safe_creds_path = creds_path(uid)
    safe_worker_url = WORKER_URL
    return f'''#!/usr/bin/env python3
# Synklav Wazuh integration script — node: {uid}
# DO NOT EDIT MANUALLY. Managed by synklav_installer.py v6.0

import sys, json, hmac, hashlib, http.client, urllib.parse, time

CREDS_FILE = "{safe_creds_path}"
WORKER_URL = "{safe_worker_url}"

try:
    with open(CREDS_FILE, "r", encoding="utf-8") as _f:
        _creds = json.load(_f)
    with open(sys.argv[1], "r", encoding="utf-8") as _f:
        _alert = _f.read()

    _uid = _creds["node_uid"]
    _key = _creds["notification_key"]
    _fcm = _creds["fcmTopicHash"]
    _ts  = str(int(time.time()))

    # Core Payload Integrity Signature
    _sig = hmac.new(
        bytes.fromhex(_key),
        (_alert + _ts + _uid).encode("utf-8"),
        hashlib.sha256
    ).hexdigest()

    _headers = {{
        "Content-Type":                 "application/json",
        "X-Synklav-Signature":          _sig,
        "X-Synklav-Timestamp":          _ts,
        "X-Synklav-Node-UID":           _uid,
        "X-Synklav-Notification-Key":   _key,
        "X-Synklav-FCM-Topic-Hash":     _fcm,
        "X-Synklav-Telegram-Chat-ID":   _creds.get("tg_chat_id", "null"),
        "X-Synklav-Telegram-Min-Level": str(_creds.get("tg_min_level", "1")),
    }}

    _parsed = urllib.parse.urlparse(WORKER_URL)
    _conn   = http.client.HTTPSConnection(_parsed.netloc, timeout=10)
    _conn.request("POST", _parsed.path or "/", body=_alert.encode("utf-8"), headers=_headers)
    _resp = _conn.getresponse()
    _resp.read()
    _conn.close()
except Exception as _e:
    print(f"[SYNKLAV ERROR] Integration execution failed: {{_e}}", file=sys.stderr)
sys.exit(0)
'''

def write_integration_script(uid: str) -> str:
    path = f"{INTEGRATIONS_DIR}/custom-synklav-{uid}"
    tmp  = path + ".tmp"
    wazuh_gid = get_wazuh_gid()
    try:
        with open(tmp, "w", encoding="utf-8") as f:
            f.write(generate_integration_script(uid))
        os.chmod(tmp, 0o750)
        try:
            os.chown(tmp, 0, wazuh_gid)
        except PermissionError:
            pass
        os.replace(tmp, path)
        return path
    except OSError as exc:
        try: os.unlink(tmp)
        except OSError: pass
        die(f"Failed to write integration script: {exc}")

# =============================================================================
#  ATOMIC XML CONF MODIFICATION
# =============================================================================
def read_ossec_conf() -> list:
    try:
        with open(OSSEC_CONF, "r", encoding="utf-8") as f:
            return f.read().splitlines()
    except OSError as exc:
        die(f"Failed to read {OSSEC_CONF}: {exc}")

def write_ossec_conf(lines: list) -> None:
    tmp = OSSEC_CONF + ".synklav.tmp"
    try:
        with open(tmp, "w", encoding="utf-8") as f:
            f.write("\n".join(lines) + "\n")
        try:
            st = os.stat(OSSEC_CONF)
            os.chmod(tmp, st.st_mode)
            os.chown(tmp, st.st_uid, st.st_gid)
        except OSError:
            pass
        os.replace(tmp, OSSEC_CONF)
    except OSError as exc:
        try: os.unlink(tmp)
        except OSError: pass
        die(f"Failed to write {OSSEC_CONF}: {exc}")

def remove_integration_blocks(lines: list, target_name: str | None) -> list:
    clean  = []
    buffer = []
    inside = False
    is_hit = False

    for line in lines:
        if _RE_INT_OPEN.match(line):
            inside = True
            buffer = [line]
            is_hit = False
            continue
        if inside:
            buffer.append(line)
            if target_name is None:
                if "custom-synklav" in line: is_hit = True
            else:
                if target_name in line: is_hit = True
            
            if _RE_INT_CLOSE.match(line):
                inside = False
                if not is_hit: clean.extend(buffer)
                buffer = []
            continue
        clean.append(line)
    
    if buffer: clean.extend(buffer)
    return clean

def inject_integration_block(lines: list, target_name: str) -> list:
    idx = -1
    for i in range(len(lines) - 1, -1, -1):
        if _RE_OSSEC_ROOT.match(lines[i]):
            idx = i
            break
    if idx == -1:
        die("Malformed configuration file: </ossec_config> tag is missing.")
    
    block = [
        "  <integration>",
        f"    <name>{target_name}</name>",
        f"    <level>{MIN_ALERT_LEVEL}</level>",
        "    <alert_format>json</alert_format>",
        "  </integration>",
    ]
    return lines[:idx] + block + lines[idx:]

# =============================================================================
#  WAZUH PROCESS REBOOT MECHANISM [A1]
# =============================================================================
def restart_wazuh() -> bool:
    log("[STATUS] Hot-rebooting Wazuh engine process core...")
    return os.system(f"{WAZUH_CONTROL} restart") == 0

# =============================================================================
#  TRANSACTIONAL ROLLBACK CONTEXT
# =============================================================================
class RollbackContext:
    def __init__(self):
        self._actions = []
    def register(self, undo_fn) -> None:
        self._actions.append(undo_fn)
    def execute(self) -> None:
        log("[STATUS] Executing transactional rollback...")
        for fn in reversed(self._actions):
            try: fn()
            except Exception as exc: log(f"[WARN] Error during rollback step: {exc}")
        log("[STATUS] Rollback completed successfully.")

# =============================================================================
#  OPERATION PROFILES
# =============================================================================
def profile_init_or_add(uid: str, notification_key: str, tg_chat_id: str, tg_min_level: str) -> None:
    target_name = f"custom-synklav-{uid}"
    rollback    = RollbackContext()
    backup      = make_backup()
    rollback.register(lambda: shutil.copyfile(backup, OSSEC_CONF))

    # Deterministic Derivation matching Flutter client output strictly: SHA256(notification_key + uid)
    fcmTopicHash = hashlib.sha256((notification_key + uid).encode("utf-8")).hexdigest()

    creds = {
        "node_uid":         uid,
        "notification_key": notification_key,
        "fcmTopicHash":     fcmTopicHash,
        "tg_chat_id":       tg_chat_id,
        "tg_min_level":     tg_min_level,
    }
    write_creds(uid, creds)
    rollback.register(lambda: delete_creds(uid))

    script_path = write_integration_script(uid)
    rollback.register(lambda p=script_path: os.path.exists(p) and os.unlink(p))

    lines = read_ossec_conf()
    lines = remove_integration_blocks(lines, target_name)
    lines = inject_integration_block(lines, target_name)
    write_ossec_conf(lines)

    if not restart_wazuh():
        log("[CRITICAL] Wazuh engine failed to restart. Reverting changes...")
        rollback.execute()
        restart_wazuh()
        sys.exit(1)
    
    log(f"[OK] Node '{uid}' successfully integrated and active.")

def profile_update_telegram(uid: str, new_tg_chat_id: str | None, new_tg_level: str) -> None:
    creds = read_creds(uid)
    creds["tg_min_level"] = new_tg_level
    if new_tg_chat_id is not None and new_tg_chat_id not in ("", "null"):
        creds["tg_chat_id"] = validate_tg_chat(new_tg_chat_id)
    write_creds(uid, creds)
    log(f"[OK] Telegram configuration updated for node '{uid}'. (No restart required)")

def profile_remove_user(uid: str) -> None:
    target_name = f"custom-synklav-{uid}"
    rollback    = RollbackContext()
    backup      = make_backup()
    rollback.register(lambda: shutil.copyfile(backup, OSSEC_CONF))

    script_path   = f"{INTEGRATIONS_DIR}/{target_name}"
    script_backup = None
    if os.path.exists(script_path):
        try:
            with open(script_path, "rb") as f: script_backup = f.read()
        except OSError: pass

    creds_backup = None
    cp = creds_path(uid)
    if os.path.exists(cp):
        try:
            with open(cp, "rb") as f: creds_backup = f.read()
        except OSError: pass

    def restore_script():
        if script_backup is not None:
            wazuh_gid = get_wazuh_gid()
            try:
                with open(script_path, "wb") as f: f.write(script_backup)
                os.chmod(script_path, 0o750)
                try: os.chown(script_path, 0, wazuh_gid)
                except PermissionError: pass
            except OSError: pass

    def restore_creds_file():
        if creds_backup is not None:
            wazuh_gid = get_wazuh_gid()
            try:
                with open(cp, "wb") as f: f.write(creds_backup)
                os.chmod(cp, 0o640)
                try: os.chown(cp, 0, wazuh_gid)
                except PermissionError: pass
            except OSError: pass

    rollback.register(restore_script)
    rollback.register(restore_creds_file)

    lines = read_ossec_conf()
    lines = remove_integration_blocks(lines, target_name)
    write_ossec_conf(lines)

    if os.path.exists(script_path): os.unlink(script_path)
    delete_creds(uid)

    if not restart_wazuh():
        log("[CRITICAL] Wazuh engine failed to restart. Reverting changes...")
        rollback.execute()
        restart_wazuh()
        sys.exit(1)

    try: os.unlink(backup)
    except OSError: pass
    log(f"[OK] Node '{uid}' successfully removed.")

def profile_purge() -> None:
    rollback = RollbackContext()
    backup = make_backup()
    rollback.register(lambda: shutil.copyfile(backup, OSSEC_CONF))

    scripts_backup = {}
    for path in glob.glob(f"{INTEGRATIONS_DIR}/custom-synklav-*"):
        basename = os.path.basename(path)
        if re.match(r'^custom-synklav-[a-zA-Z0-9_-]+$', basename):
            try:
                with open(path, "rb") as f: scripts_backup[path] = f.read()
            except OSError: pass

    creds_backup_map = {}
    for path in glob.glob(f"{INTEGRATIONS_DIR}/.synklav-*.creds"):
        try:
            with open(path, "rb") as f: creds_backup_map[path] = f.read()
        except OSError: pass

    def restore_all_scripts():
        wazuh_gid = get_wazuh_gid()
        for p, content in scripts_backup.items():
            try:
                with open(p, "wb") as f: f.write(content)
                os.chmod(p, 0o750)
                try: os.chown(p, 0, wazuh_gid)
                except PermissionError: pass
            except OSError: pass

    def restore_all_creds():
        wazuh_gid = get_wazuh_gid()
        for p, content in creds_backup_map.items():
            try:
                with open(p, "wb") as f: f.write(content)
                os.chmod(p, 0o640)
                try: os.chown(p, 0, wazuh_gid)
                except PermissionError: pass
            except OSError: pass

    rollback.register(restore_all_scripts)
    rollback.register(restore_all_creds)

    lines = read_ossec_conf()
    lines = remove_integration_blocks(lines, target_name=None)
    write_ossec_conf(lines)

    for path in list(scripts_backup.keys()):
        try: os.unlink(path)
        except OSError as exc: log(f"[WARN] Failed to delete {path}: {exc}")

    for path in list(creds_backup_map.keys()):
        try:
            size = os.path.getsize(path)
            with open(path, "r+b") as f:
                f.write(b'\x00' * size)
                f.flush()
                os.fsync(f.fileno())
            os.unlink(path)
        except OSError as exc:
            log(f"[WARN] Failed to securely delete {path}: {exc}")

    if not restart_wazuh():
        log("[CRITICAL] Wazuh engine failed to restart. Reverting changes...")
        rollback.execute()
        restart_wazuh()
        sys.exit(1)

    purge_backups()
    try: os.unlink(backup)
    except OSError: pass
    log("[OK] Complete purge. All Synklav artifacts have been removed.")

# =============================================================================
#  MAIN ENTRY POINT & ARGPARSE
# =============================================================================
def main() -> None:
    print(BANNER)
    if os.getuid() != 0:
        die("Script must be run as root (sudo).")
    if not os.path.exists(OSSEC_CONF):
        die(f"{OSSEC_CONF} not found. Are you running this on the Wazuh Manager?")
    if not os.path.isdir(INTEGRATIONS_DIR):
        die(f"Integrations directory not found: {INTEGRATIONS_DIR}")
    if not os.path.isfile(WAZUH_CONTROL):
        die(f"{WAZUH_CONTROL} not found. Is Wazuh installed?")
    
    acquire_lock()

    parser = argparse.ArgumentParser(
        description="Synklav Integration Installer v6.0",
        formatter_class=argparse.RawTextHelpFormatter
    )
    parser.add_argument("--profile", type=int, choices=[1, 2, 3, 4, 5],
        help="1=Init  2=Add  3=Update Telegram  4=Remove  5=Purge")
    parser.add_argument("--uid",      type=str)
    parser.add_argument("--key",      type=str)
    parser.add_argument("--tg-chat",  type=str, default=None)
    parser.add_argument("--tg-level", type=str, default=None)
    args = parser.parse_args()

    exec_profile = args.profile
    if not exec_profile:
        print("\nSelect execution profile:")
        print("  1) INITIALIZE      - Fresh deployment of Synklav core container.")
        print("  2) ADD USER        - Append a new user profile / node UID.")
        print("  3) UPDATE TELEGRAM - Change the minimum alert level for Telegram.")
        print("  4) REMOVE USER     - Delete a single specific user profile cleanly.")
        print("  5) PURGE ALL       - Complete atomic removal of all Synklav structures.\n")
        try:
            exec_profile = int(input("➔ Enter profile selection (1-5): ").strip())
            if exec_profile not in range(1, 6):
                raise ValueError
        except (ValueError, EOFError):
            die("Invalid selection.")

    if exec_profile in (1, 2):
        uid = args.uid or input("➔ Enter target UNIQUE NODE UID (from Synklav App): ").strip()
        uid = validate_node_uid(uid)
        key = args.key or input("➔ Enter NOTIFICATION KEY (from Synklav App): ").strip()
        key = validate_notification_key(key)
        
        tg_chat  = args.tg_chat
        tg_level = args.tg_level
        if tg_chat is None:
            resp = input("➔ Active secondary Telegram routing? (y/n): ").strip().lower()
            if resp in ("y", "yes"):
                tg_chat  = input("   - Target Chat ID string: ").strip()
                tg_level = input("   - Enter MINIMUM alert level for Telegram (1-15): ").strip()
            else:
                tg_chat  = "null"
                tg_level = "1"
        tg_chat  = validate_tg_chat(tg_chat or "null")
        tg_level = validate_tg_level(tg_level or "1")
        
        profile_init_or_add(uid, key, tg_chat, tg_level)

    elif exec_profile == 3:
        uid = validate_node_uid(args.uid or input("➔ Enter target UNIQUE NODE UID: ").strip())
        tg_level = args.tg_level
        tg_chat  = args.tg_chat
        if tg_level is None:
            tg_level = input("➔ Enter the NEW minimum alert level for Telegram (1-15): ").strip()
        tg_level = validate_tg_level(tg_level)
        if tg_chat is None:
            resp = input("➔ Change Chat ID as well? (y/n): ").strip().lower()
            if resp in ("y", "yes"):
                tg_chat = input("   - New Chat ID string: ").strip()
        profile_update_telegram(uid, tg_chat, tg_level)

    elif exec_profile == 4:
        uid = validate_node_uid(args.uid or input("➔ Enter target UNIQUE NODE UID: ").strip())
        confirm = input(f"⚠  Type the UID '{uid}' to confirm deletion: ").strip()
        if confirm != uid:
            die("Incorrect confirmation. Operation cancelled.", 0)
        profile_remove_user(uid)

    elif exec_profile == 5:
        confirm = input("⚠  Type CONFIRM-PURGE to delete all infrastructure: ").strip()
        if confirm == "CONFIRM-PURGE":
            profile_purge()
        else:
            die("Incorrect confirmation. Operation cancelled.", 0)

if __name__ == "__main__":
    main()
