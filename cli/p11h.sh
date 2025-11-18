#!/bin/bash

ROUTER="http://192.168.8.1"
USER="admin"
PASS="REPLACE HERE"

USER_B64=$(echo -n "$USER" | base64)
PASS_MD5=$(echo -n "$PASS" | md5sum | awk '{print $1}')
PASS_B64=$(echo -n "$PASS_MD5" | base64)

usage() {
  echo "Usage:"
  echo "  $0 status"
  echo "  $0 lock <earfcn> <pci>"
  echo "  $0 unlock"
  echo "  $0 reboot"
  exit 1
}

do_login() {
  echo "[*] Logging in..."
  RESP=$(curl -s -c cookies.txt -X POST "$ROUTER/reqproc/proc_post" \
    -d "isTest=false&goformId=LOGIN&username=$USER_B64&password=$PASS_B64")

  echo "[+] Login response: $RESP"
}

do_lock() {
  do_login
  EARFCN="$1"
  PCI="$2"

  echo "[*] Locking EARFCN=$EARFCN PCI=$PCI ..."
  RESP=$(curl -s -b cookies.txt -X POST "$ROUTER/reqproc/proc_post" \
    -d "isTest=false&goformId=LOCK_FREQUENCY&actionlte=1&uarfcnlte=$EARFCN&cellParaIdlte=$PCI")

  echo "[+] Lock response: $RESP"
}

do_unlock() {
  do_login

  echo "[*] Unlocking cell..."
  RESP=$(curl -s -b cookies.txt -X POST "$ROUTER/reqproc/proc_post" \
    -d "isTest=false&goformId=LOCK_FREQUENCY&actionlte=0&uarfcnlte=&cellParaIdlte=")

  echo "[+] Unlock response: $RESP"
}

do_reboot() {
  do_login

  echo "[*] Rebooting router..."
  RESP=$(curl -s -b cookies.txt -X POST "$ROUTER/reqproc/proc_post" \
    -d "isTest=false&goformId=REBOOT_DEVICE")

  if [ -z "$RESP" ]; then
    echo "[+] Reboot command sent successfully (router is restarting)"
  else
    echo "[+] Reboot response: $RESP"
  fi
}

do_status() {
  do_login
  echo "[*] Getting system status..."
  RESP=$(curl -s -b cookies.txt \
    "$ROUTER/reqproc/proc_get?isTest=false&cmd=system_status")

  echo "[+] Status raw JSON:"
  echo "$RESP" | sed 's/,/\n/g' | sed 's/{//;s/}//'
}

case "$1" in
  lock)   do_lock "$2" "$3" ;;
  unlock) do_unlock ;;
  reboot) do_reboot ;;
  status) do_status ;;
  *)      usage ;;
esac
