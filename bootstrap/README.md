# bootstrap — bare metal to Ansible-ready

Turns a powered-off Lenovo Tiny into a headless Debian 13 box that Ansible can
drive: the admin user (ADMIN_USER) with passwordless sudo, your SSH key installed, key-only
auth, and `python3`/`sudo`/`openssh-server` already present.

Hostname is deliberately **not** baked in — one generic install, and `site.yml`
assigns `acheron`/`cocytus` from inventory. Same image, both boxes.

## First: fill the three markers in `preseed.cfg`

```bash
# 1. console password hash (break-glass only — SSH is key-only)
mkpasswd -m sha-512                       # paste into REPLACE_ME_SHA512_HASH
# 2 & 3. your public key
cat ~/.ssh/id_ed25519.pub                 # paste into REPLACE_ME_SSH_ED25519_PUBKEY
```

Because SSH password auth is disabled, the published hash grants nothing remote
— but still use a throwaway, not a reused password.

## Install method A — network preseed (recommended, no ISO surgery)

Because this repo can sit public on GitHub, the installer can pull the preseed
straight from it.

1. Flash a stock Debian 13 netinst ISO to USB (`dd` or Rufus/Etcher).
2. Boot the Tiny, at the installer menu press `Tab`/`e` and append:
   ```
   auto=true priority=critical preseed/url=https://raw.githubusercontent.com/<you>/ark-fleet/main/bootstrap/preseed.cfg  # note: tokens must be pre-rendered; prefer the netboot method
   ```
3. Walk away. It installs, hardens, reboots, and comes up SSH-ready.

## Install method B — fully unattended USB (walk-away, zero keystrokes)

Bake the preseed into the ISO so there's nothing to type:

```bash
sudo apt install xorriso p7zip-full
cd bootstrap
./build-iso.sh ~/Downloads/debian-13.*-amd64-netinst.iso ark-tiny-auto.iso
sudo dd if=ark-tiny-auto.iso of=/dev/sdX bs=4M status=progress oflag=sync
```

Boot each Tiny from it; the "ark-fleet unattended install" entry auto-selects.

## Then: hand off to Ansible

```bash
ssh <ADMIN_USER>@<host-ip> true      # confirm key-only login works on both boxes
cd ..                            # repo root
ansible all -m ping              # both hosts answer
ansible-playbook site.yml        # sets hostname + builds the cluster
```

That's bare metal to running ARK cluster in two commands after the install.
