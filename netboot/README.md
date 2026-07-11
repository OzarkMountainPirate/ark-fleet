# netboot — install the Tinys over the network (no USB)

Reusable PXE stack: `dnsmasq` (proxyDHCP + TFTP) plus `nginx` (serves the
preseed over HTTP). Runs on any Docker host on the LAN. Boot a Tiny from its NIC and it
installs Debian 13 unattended, then reboots SSH-ready for Ansible.

**Why proxyDHCP:** dnsmasq assigns no IPs and answers no DNS — it only adds the
PXE "here's your bootloader" hint. It coexists with your pfSense DHCP untouched.
That's what makes this reusable: leave it running and any future box PXE-boots
into the same menu (add entries to `menu/` for other OSes later).

## Prerequisites

- **Provide a filled preseed.** `setup.sh` looks for it in this order (first
  match wins; override with `PRESEED=/path`):
  1. `$PRESEED` env var
  2. `./preseed.cfg` — beside this stack (use this for a standalone deploy,
     e.g. `/opt/containers/netboot/preseed.cfg`)
  3. `../bootstrap/preseed.cfg` — when running from inside the ark-fleet repo

  Copy `bootstrap/preseed.cfg` to whichever location fits and fill its two
  markers (SSH public key + a throwaway console password hash). `setup.sh`
  **refuses to run** while `REPLACE_ME` markers remain, so it can't publish a
  preseed that would lock you out.
- On each Tiny's firmware: enable **network/PXE boot** and either put the NIC
  first in boot order or use the one-time boot menu (F12 on Lenovo). UEFI is
  fine (the stack serves both UEFI and legacy BIOS).

### Fill the preseed markers

From wherever your preseed lives (standalone example shown):

```bash
# SSH key: the key of the host you'll run Ansible FROM (make one if needed:
#   ssh-keygen -t ed25519 -C "you@controlnode")
HASH="$(openssl passwd -6)"                 # prompts twice; never hits shell history
PUBKEY="$(cat ~/.ssh/id_ed25519.pub)"
sudo sed -i "s|REPLACE_ME_SHA512_HASH|$HASH|"          preseed.cfg
sudo sed -i "s|REPLACE_ME_SSH_ED25519_PUBKEY|$PUBKEY|" preseed.cfg
# verify VALUES, not just marker absence — a failed openssl (mismatched
# entries) outputs an empty hash and still passes a marker-absence check:
grep user-password-crypted preseed.cfg      # must end with  password $6$...
grep "echo 'ssh-" preseed.cfg               # must show your public key
# (setup.sh also enforces both and refuses to publish an empty credential)
```

The `|` sed delimiter is deliberate — the hash and key both contain `/`, which
would break `s/.../.../`; neither contains `|`.

## Configure (netboot/.env)

Everything deployment-specific lives in `.env` — the one file you edit per
host/network:

| var | meaning | default |
|-----|---------|---------|
| `HTTP_HOST` | this host's LAN IP (serves preseed; baked into the boot menus) | 192.168.1.10 |
| `HTTP_PORT` | preseed HTTP port (pick one nothing else uses) | 8079 |
| `LAN_SUBNET` | proxyDHCP scope — your LAN network address (the .0) | 192.168.1.0 |
| `SUITE` | Debian release to netboot | trixie |

`docker-compose.yml` reads `HTTP_PORT`; `setup.sh` reads all four and renders the
configs from them (`dnsmasq.conf` from `dnsmasq.conf.tmpl`, plus the boot menus).
To retarget a different subnet or host, change `.env` and re-run `setup.sh` — that
portability is the point.

## Bring it up (on the Docker host)

```bash
cd netboot                         # or /opt/containers/netboot for a standalone deploy
./setup.sh                         # reads .env; pass an IP as arg 1 to override HTTP_HOST
sudo docker compose up -d --build
curl -s http://192.168.1.10:8079/preseed.cfg | head   # confirm nginx serves it
sudo docker compose logs -f dnsmasq                   # watch PXE exchanges live
```

`setup.sh` renders `dnsmasq.conf` and the boot menus from `.env`, downloads the
Debian 13 netboot files into `tftp/` (idempotent — skips the download on re-runs;
force with `REFRESH=1`), and publishes the preseed. **Edit `.env`, re-run
`setup.sh`, then `docker compose up -d`** whenever config changes. Note
`dnsmasq.conf` is generated — edit `dnsmasq.conf.tmpl`, not the rendered file.



## Install the Tinys

Power them on and PXE-boot. They pick up an IP from DHCP, grab the bootloader
from dnsmasq, load the installer over TFTP, pull the preseed over HTTP, and run
the unattended install. The base system still pulls packages from the Debian
mirror (that's what "netinst" means), so the Tinys need internet during install.

When they reboot, confirm and hand off:

```bash
ssh <ADMIN_USER>@<host-ip> true    # key-only login works
cd ..
ansible-playbook site.yml
```

## Stable IPs

The inventory expects fixed IPs. Add DHCP reservations on your router for
the hosts' MACs so they always land there — or edit `inventory/hosts.yml` to
whatever they get.

## Preventing reinstall loops (post-install boot behavior)

A freshly installed host that still PXE-boots first will happily reinstall
itself forever. The state "this host is already built" has to live somewhere;
pick one (or combine the first two):

1. **Firmware boot order — disk first, NIC second (recommended here).** UEFI
   falls through the boot order: an EMPTY disk has no boot entry, so a fresh
   machine automatically lands on PXE and installs; once installed, the disk
   boots instantly with no PXE timeout. Reprovision = F12 one-time PXE boot
   (or wipe the disk). Zero moving parts, no per-boot delay.
2. **Server-side suppression — `INSTALLED_MACS` in `.env`.** For the NIC-first
   workflow: list installed MACs and dnsmasq ignores their PXE requests
   (`dhcp-ignore=tag:installed`), so firmware falls through to disk. Grab the
   MAC from the dnsmasq log, add it, `./setup.sh && docker compose restart
   dnsmasq`. Costs a PXE timeout (~10-30s) every boot while NIC stays first.
   Remove the MAC to reprovision — no touching the machine.
3. **Out-of-band control (the enterprise answer).** Servers use a BMC
   (iDRAC/iLO/IPMI/Redfish) to set a one-time boot device remotely; permanent
   order stays disk-first. The Tiny-class equivalent is Intel AMT/vPro if the
   CPU/chipset support it. At fleet scale this is driven by provisioning
   systems (Foreman, MAAS, Cobbler, iPXE+matchbox) that track per-host state
   and serve boot files conditionally — the industrial version of option 2.

## Troubleshooting

- **No PXE offer / dnsmasq log stays silent:** dnsmasq is host-networked, so
  inbound DHCP broadcasts must pass the HOST's firewall input chain. On a
  hardened host (nftables `policy drop`), open these before anything will work:

  ```
  udp dport 67 accept comment "pxe: dhcp/proxydhcp discover (saddr is 0.0.0.0)"
  ip saddr <LAN>/24 udp dport 69 accept comment "pxe: tftp"
  ip saddr <LAN>/24 udp dport 4011 accept comment "pxe: proxydhcp service"
  ```

  Port 67 must NOT be source-restricted to the LAN — PXE DISCOVERs come from
  `0.0.0.0` (the client has no IP yet). TFTP's data channel needs no extra rule
  (server replies from an ephemeral port; conntrack `established,related` covers
  it). The nginx preseed port needs nothing: it's DNAT'd through the forward
  chain, not input. Test the path without touching a Tiny:
  `sudo nmap --script broadcast-dhcp-discover` from another LAN box — the
  DISCOVER must appear in `docker compose logs -f dnsmasq`. Silent log = blocked
  input or L2 problem; visible DISCOVER = server side healthy.
- **DHCP/ACK works but no TFTP ever happens (log shows repeating DHCP cycles,
  zero `dnsmasq-tftp` lines):** two dnsmasq proxy-mode rules interact here.
  (1) In proxyDHCP mode dnsmasq IGNORES `dhcp-boot` — boot info can only be
  delivered via `pxe-service` (option 43). (2) `pxe-prompt` must NOT be set:
  it forces the legacy PXE boot-menu protocol, which many UEFI firmwares can't
  speak — they get the ACK, stall, and loop discovery. Correct recipe (what
  this template ships): `pxe-service` entries per arch, no `pxe-prompt`; with
  a single matching service dnsmasq hands UEFI clients the boot file directly.
- **DHCP request logged but dnsmasq sends NO response at all (no `PXE(...)
  proxy` lines):** the config has neither `pxe-service` nor `pxe-prompt` — in
  proxy mode `dhcp-boot` alone produces no PXE response. Add `pxe-service`.
- **Machine skips PXE entirely ("no operating system found", no `Start PXE over
  IPv4` banner):** the firmware never tried the network. On Lenovo Tinys: F1 →
  enable PXE IPv4 / network boot (often factory-disabled), disable Secure Boot
  for the install, then F12 and pick the IPv4 network entry.
- **No PXE offer (L2):** dnsmasq must be on the same L2 as the Tinys (it is, via
  `network_mode: host`). Watch `docker compose logs -f dnsmasq` — you should see
  the client's `client-arch` and the boot file it's handed.
- **UEFI vs BIOS:** arch 7/9 → `bootnetx64.efi`, arch 0 → `pxelinux.0`. If a Tiny
  loops, check which arch it announced in the log and that the file exists in
  `tftp/`.
- **Preseed not found:** browse to `http://<HTTP_HOST>:8079/preseed.cfg` — nginx must
  serve it. Re-run `setup.sh` if you edited the preseed.

## Reuse for future projects

This is generic infra. To netboot something else, drop its kernel/initrd under
`tftp/` and add a `menuentry` (GRUB) / `LABEL` (pxelinux) in `menu/`, re-run
`setup.sh`. If you'd rather have a big graphical menu of every OS installer,
`netboot.xyz` slots in here — point its TFTP at this same dnsmasq and it becomes
the boot menu; the proxyDHCP layer stays exactly as-is.
