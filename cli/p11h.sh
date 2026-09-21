#!/bin/bash

ROUTER="http://192.168.8.1"
USER="admin"
PASS="REPLACE HERE"

# Local credentials (gitignored) override the placeholders above. Create
# cli/p11h.conf from cli/p11h.conf.example and fill in your real password.
CONF="$(cd "$(dirname "$0")" && pwd)/p11h.conf"
[ -f "$CONF" ] && . "$CONF"

if [ -z "$PASS" ] || [ "$PASS" = "REPLACE HERE" ]; then
  echo "[!] No router credentials configured." >&2
  echo "    Create $(dirname "$0")/p11h.conf containing:" >&2
  echo '      ROUTER="http://192.168.8.1"' >&2
  echo '      USER="admin"' >&2
  echo '      PASS="your-router-password"' >&2
  exit 1
fi

USER_B64=$(echo -n "$USER" | base64)
PASS_MD5=$(echo -n "$PASS" | md5sum | awk '{print $1}')
PASS_B64=$(echo -n "$PASS_MD5" | base64)

# ---------------------------------------------------------------------------
# Firmware CSRF/session model (ZTE "Demo-Webs", verified empirically):
#   - Sessions are bound to the client IP server-side; no cookies are used.
#   - GET requests (proc_get) never need a session or token.
#   - When logged OUT: get_token returns empty; only LOGIN is exempt from the
#     CSRF filter (the WebUI's own AJAX sends "X-Requested-With:
#     XMLHttpRequest", which we replicate; without it POSTs are rejected with
#     {"result":"illegal request for csrfToken"}).
#   - When logged IN: get_token returns a token and EVERY POST (incl. LOGOUT)
#     must carry it as CSRFToken; violations return a silent empty body.
#   - Login lockout: 5 wrong attempts => ~300s lockout (psw_fail_num_str /
#     login_lock_time via proc_get, read-only, safe to check).
# ---------------------------------------------------------------------------
XRW="X-Requested-With: XMLHttpRequest"

usage() {
  echo "Usage:"
  echo "  $0 status"
  echo "  $0 lockinfo   - show current cell-lock state"
  echo "  $0 lock <earfcn> <pci>"
  echo "  $0 unlock"
  echo "  $0 reboot"
  exit 1
}

get_token() {
  # Token is only available while logged in; empty output when logged out.
  TOKEN=$(curl -s -H "$XRW" "$ROUTER/reqproc/proc_get?isTest=false&cmd=get_token" \
    | sed -n 's/.*"token":"\([^"]*\)".*/\1/p')
}

is_logged_in() {
  curl -s -H "$XRW" "$ROUTER/reqproc/proc_get?isTest=false&cmd=loginfo" \
    | grep -q '"loginfo":"ok"'
}

wait_out_lockout() {
  # psw_fail_num_str==MAX with login_lock_time==-1 means the login is
  # hard-locked until the next reboot (observed on this firmware).
  STATE=$(get_cmd "psw_fail_num_str,login_lock_time&multi_data=1")
  FAILS=$(sed -n 's/.*"psw_fail_num_str":"\([^"]*\)".*/\1/p' <<<"$STATE")
  LOCK=$(sed -n 's/.*"login_lock_time":"\([^"]*\)".*/\1/p' <<<"$STATE")

  if [ "$FAILS" = "5" ] && [ "$LOCK" = "-1" ]; then
    echo "[!] Router login is hard-locked (5 failed attempts reached)." >&2
    echo "    Power-cycle the router once to clear it, then re-run this command." >&2
    exit 1
  fi

  if [ -n "$LOCK" ] && [ "$LOCK" != "-1" ] && [ "$LOCK" -gt 0 ] 2>/dev/null; then
    if [ "$LOCK" -le 320 ]; then
      echo "[*] Login locked out; waiting ${LOCK}s for the router timer..."
      sleep $((LOCK + 3))
    else
      echo "[!] Login locked out for ${LOCK}s; re-run this command later." >&2
      exit 1
    fi
  fi
}

login_and_arm() {
  # LOGOUT first: it is accepted without a token even when logged out, and a
  # LOGIN issued while a stale/zombie session exists can kill the session and
  # leave the CSRF token un-armed.
  post_cmd_raw "goformId=LOGOUT" > /dev/null

  RESP=$(post_cmd_raw "goformId=LOGIN&username=$USER_B64&password=$PASS_B64")
  echo "[+] Login response: $RESP"
  case "$RESP" in
    *'"result":"0"'*|*'"result":"4"'*) ;;
    *'"result":"1"'*)
      echo "[!] Login failed: wrong password, duplicate session or lockout." >&2
      echo "    Check: curl '$ROUTER/reqproc/proc_get?isTest=false&cmd=psw_fail_num_str,login_lock_time&multi_data=1'" >&2
      exit 1 ;;
    *)
      echo "[!] Unexpected login response: $RESP" >&2
      exit 1 ;;
  esac

  get_token
  if [ -z "$TOKEN" ]; then
    echo "[!] Logged in but router did not issue a CSRF token" >&2
    exit 1
  fi
}

ensure_session() {
  if is_logged_in; then
    echo "[*] Session already active, reusing it"
    get_token
    if [ -n "$TOKEN" ]; then
      return
    fi
    echo "[*] CSRF token expired; refreshing session..."
  else
    wait_out_lockout
    echo "[*] Logging in..."
  fi
  login_and_arm
}

post_cmd_raw() {
  # For requests that are CSRF-exempt (LOGIN while logged out)
  curl -s -H "$XRW" -X POST "$ROUTER/reqproc/proc_post" -d "isTest=false&$1"
}

post_cmd() {
  # Authenticated POST: every goform action needs the current CSRF token
  curl -s -H "$XRW" -X POST "$ROUTER/reqproc/proc_post" \
    -d "isTest=false&$1&CSRFToken=$TOKEN"
}

get_cmd() {
  curl -s -H "$XRW" "$ROUTER/reqproc/proc_get?isTest=false&cmd=$1"
}

do_lock() {
  EARFCN="$1"
  PCI="$2"
  ensure_session

  echo "[*] Locking EARFCN=$EARFCN PCI=$PCI ..."
  RESP=$(post_cmd "goformId=LOCK_FREQUENCY&actionlte=1&uarfcnlte=$EARFCN&cellParaIdlte=$PCI")

  echo "[+] Lock response: $RESP"
  case "$RESP" in
    *success*) echo "[+] Cell lock applied" ;;
    *)         echo "[!] Lock may have failed (empty response = CSRF/session rejection)" ;;
  esac
}

do_unlock() {
  ensure_session

  echo "[*] Unlocking cell..."
  RESP=$(post_cmd "goformId=LOCK_FREQUENCY&actionlte=0&uarfcnlte=&cellParaIdlte=")

  echo "[+] Unlock response: $RESP"
  case "$RESP" in
    *success*) echo "[+] Cell lock removed" ;;
    *)         echo "[!] Unlock may have failed (empty response = CSRF/session rejection)" ;;
  esac
}

do_reboot() {
  ensure_session

  echo "[*] Rebooting router..."
  RESP=$(post_cmd "goformId=REBOOT_DEVICE")

  if [ -z "$RESP" ]; then
    echo "[+] Reboot command sent (router is restarting)"
  else
    echo "[+] Reboot response: $RESP"
  fi
}

do_status() {
  echo "[*] Getting system status..."
  RESP=$(get_cmd "system_status")

  echo "[+] Status raw JSON:"
  echo "$RESP" | sed 's/,/\n/g' | sed 's/{//;s/}//'
}

do_lockinfo() {
  echo "[*] Getting cell-lock state..."
  RESP=$(get_cmd "nv_arfcn,nv_pci,actionlte,cellParaIdlte,uarfcnlte,CellLockSet&multi_data=1")

  echo "[+] Lock state raw JSON: $RESP"
  echo "$RESP" | sed 's/,/\n/g' | sed 's/{//;s/}//'
}

case "$1" in
  lock)     do_lock "$2" "$3" ;;
  unlock)   do_unlock ;;
  reboot)   do_reboot ;;
  status)   do_status ;;
  lockinfo) do_lockinfo ;;
  *)        usage ;;
esac
