#!/usr/bin/env bash
#############################################################################
# setup.sh — render the netboot configs from .env and lay out the TFTP + HTTP
# roots. Idempotent and re-runnable.
#
#   ./setup.sh [HTTP_HOST_IP]
#
# All config lives in .env (single source of truth), also read by
# docker-compose. Values:
#   HTTP_HOST   this host's LAN IP (serves preseed; baked into boot menus)
#   HTTP_PORT   preseed HTTP port (default 8080)
#   LAN_SUBNET  proxyDHCP scope, e.g. 192.168.1.0
#   SUITE       Debian release (default trixie)
# Passing HTTP_HOST as arg 1 overrides the .env value.
#
# Preseed resolution (first match wins; override with PRESEED=/path):
#   1. $PRESEED   2. ./preseed.cfg   3. ../bootstrap/preseed.cfg
#
# Force re-download of the installer:  REFRESH=1 ./setup.sh
#############################################################################
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
TFTP="$HERE/tftp"
HTTP="$HERE/http"

# read KEY=VALUE from .env (keep comments on their own lines in .env)
_env() { if [ -f "$HERE/.env" ]; then sed -n "s/^$1=//p" "$HERE/.env" | head -n1; fi; }

# --- config: arg overrides .env; .env is the single source of truth ---------
HTTP_HOST="${1:-$(_env HTTP_HOST)}"
: "${HTTP_HOST:?set HTTP_HOST in .env or pass as arg 1 (e.g. 192.168.1.10)}"
HTTP_PORT="${HTTP_PORT:-$(_env HTTP_PORT)}"; HTTP_PORT="${HTTP_PORT:-8080}"
LAN_SUBNET="${LAN_SUBNET:-$(_env LAN_SUBNET)}"
: "${LAN_SUBNET:?set LAN_SUBNET in .env (e.g. 192.168.1.0)}"
SUITE="${SUITE:-$(_env SUITE)}"; SUITE="${SUITE:-trixie}"
ADMIN_USER="${ADMIN_USER:-$(_env ADMIN_USER)}"; ADMIN_USER="${ADMIN_USER:-admin}"
ADMIN_FULLNAME="${ADMIN_FULLNAME:-$(_env ADMIN_FULLNAME)}"; ADMIN_FULLNAME="${ADMIN_FULLNAME:-$ADMIN_USER}"
NET_DOMAIN="${NET_DOMAIN:-$(_env NET_DOMAIN)}"; NET_DOMAIN="${NET_DOMAIN:-lan}"
TIMEZONE="${TIMEZONE:-$(_env TIMEZONE)}"; TIMEZONE="${TIMEZONE:-Etc/UTC}"
NETBOOT_URL="http://deb.debian.org/debian/dists/${SUITE}/main/installer-amd64/current/images/netboot/netboot.tar.gz"

# --- locate the preseed -----------------------------------------------------
if [ -z "${PRESEED:-}" ]; then
  for cand in "$HERE/preseed.cfg" "$HERE/../bootstrap/preseed.cfg"; do
    if [ -f "$cand" ]; then PRESEED="$cand"; break; fi
  done
fi
if [ -z "${PRESEED:-}" ] || [ ! -f "${PRESEED:-}" ]; then
  cat >&2 <<MSG
ERROR: no preseed found. Looked for (in order):
  \$PRESEED env var : ${PRESEED:-<unset>}
  $HERE/preseed.cfg
  $HERE/../bootstrap/preseed.cfg
Fix: place your filled preseed at  $HERE/preseed.cfg
(copy it from the repo's bootstrap/preseed.cfg and fill the markers), then re-run.
MSG
  exit 1
fi
if grep -q 'REPLACE_ME_' "$PRESEED"; then
  echo "ERROR: $PRESEED still has REPLACE_ME markers (SSH key / password hash)." >&2
  echo "       An unfilled preseed produces a box you cannot log into. Fill them first." >&2
  exit 1
fi
# Markers gone is not enough — a failed fill (e.g. openssl password mismatch
# outputs an EMPTY string) removes the marker but leaves the value blank, which
# passes the check above and then either prompts mid-install (password) or
# locks you out entirely (SSH key). Require actual values:
if grep -Eq 'user-password-crypted[[:space:]]+password[[:space:]]*$' "$PRESEED"; then
  echo "ERROR: user-password-crypted has an EMPTY value in $PRESEED." >&2
  echo "       Likely a failed 'openssl passwd -6' (mismatched entries output nothing)." >&2
  echo "       Regenerate the hash and re-fill the line." >&2
  exit 1
fi
if ! grep -q "echo 'ssh-" "$PRESEED"; then
  echo "ERROR: authorized_keys line in $PRESEED has no SSH public key (expected ssh-...)." >&2
  echo "       An empty key means NO login after install. Re-fill it from your ~/.ssh/*.pub." >&2
  exit 1
fi

echo ">> host $HTTP_HOST  port $HTTP_PORT  subnet $LAN_SUBNET  suite $SUITE"
echo ">> preseed: $PRESEED"
mkdir -p "$TFTP" "$HTTP"

# --- render dnsmasq.conf from template (subnet from .env) -------------------
if [ -f "$HERE/dnsmasq.conf.tmpl" ]; then
  sed "s/__LAN_SUBNET__/$LAN_SUBNET/g" "$HERE/dnsmasq.conf.tmpl" > "$HERE/dnsmasq.conf"
  # Append installed-host tags from .env (see dhcp-ignore=tag:installed in the
  # template). Reprovision a host by removing its MAC and re-running this.
  INSTALLED_MACS="${INSTALLED_MACS:-$(_env INSTALLED_MACS)}"
  if [ -n "${INSTALLED_MACS:-}" ]; then
    {
      echo ""
      echo "# provisioned hosts (from .env INSTALLED_MACS) — PXE ignored"
      IFS=','; for mac in $INSTALLED_MACS; do
        printf 'dhcp-host=%s,set:installed\n' "$(echo "$mac" | tr -d ' ')"
      done; unset IFS
    } >> "$HERE/dnsmasq.conf"
    echo ">> rendered dnsmasq.conf (PXE suppressed for: $INSTALLED_MACS)"
  else
    echo ">> rendered dnsmasq.conf"
  fi
else
  echo "ERROR: dnsmasq.conf.tmpl missing (needed to render dnsmasq.conf)." >&2
  exit 1
fi

# --- fetch installer (idempotent; REFRESH=1 forces a re-download) -----------
if [ -f "$TFTP/debian-installer/amd64/bootnetx64.efi" ] && [ "${REFRESH:-0}" != "1" ]; then
  echo ">> installer already present (run with REFRESH=1 to re-download)"
else
  echo ">> downloading Debian ${SUITE} netboot files"
  tmp="$(mktemp)"
  curl -fSL "$NETBOOT_URL" -o "$tmp"
  tar -xzf "$tmp" -C "$TFTP"
  rm -f "$tmp"
fi

# --- render boot menus (host + port from .env) ------------------------------
echo ">> rendering boot menus (UEFI grub + BIOS pxelinux)"
install -Dm644 "$HERE/menu/grub.cfg" "$TFTP/debian-installer/amd64/grub/grub.cfg"
sed -i -e "s/__HTTP_HOST__/$HTTP_HOST/g" -e "s/__HTTP_PORT__/$HTTP_PORT/g" \
  "$TFTP/debian-installer/amd64/grub/grub.cfg"
install -Dm644 "$HERE/menu/pxelinux.default" "$TFTP/pxelinux.cfg/default"
sed -i -e "s/__HTTP_HOST__/$HTTP_HOST/g" -e "s/__HTTP_PORT__/$HTTP_PORT/g" \
  "$TFTP/pxelinux.cfg/default"

# --- publish preseed over HTTP (rendering identity tokens from .env) --------
echo ">> publishing preseed at http://$HTTP_HOST:$HTTP_PORT/preseed.cfg (user: $ADMIN_USER)"
install -Dm644 "$PRESEED" "$HTTP/preseed.cfg"
sed -i \
  -e "s/__ADMIN_USER__/$ADMIN_USER/g" \
  -e "s/__ADMIN_FULLNAME__/$ADMIN_FULLNAME/g" \
  -e "s/__NET_DOMAIN__/$NET_DOMAIN/g" \
  -e "s|__TIMEZONE__|$TIMEZONE|g" \
  "$HTTP/preseed.cfg"
if grep -q '__[A-Z_]*__' "$HTTP/preseed.cfg"; then
  echo "ERROR: unrendered tokens remain in the published preseed:" >&2
  grep -o '__[A-Z_]*__' "$HTTP/preseed.cfg" | sort -u >&2
  exit 1
fi

echo ">> done. Next: sudo docker compose up -d"
