# ark-fleet

Infrastructure-as-Code to provision two Lenovo Tiny hosts into a single
**ARK: Survival Evolved** cluster, wrapped around the [`gamectl`](https://github.com/OzarkMountainPirate/utilities/tree/main/bash-scripts/ark-ase)
toolkit. Ansible is the control plane; `gamectl` + systemd `ark@.service` is the
runtime. No Docker, no daemon, no Jenkins. **Target OS: Debian 13 (trixie)** —
SteamCMD comes from `non-free`; `gamectl`'s paths are unchanged from its 24.04 origins.

## Why no Jenkins

There is no build here. A game server has no compile step and no artifact to
promote, so a CI *orchestrator* is solving a problem you don't have. The DevOps
value is **reproducibility and config management**, and that's Ansible + Git.
If you want a pipeline UI, the only justified use is *linting* (shellcheck /
ansible-lint / yamllint on push) — wired up under "CI" below, free on GitHub
Actions for this public repo. Jenkins is the
wrong shape for all of it.

## Topology

```
        Router/firewall (192.168.1.1)       ── port-forwards game+query UDP ──┐
                                                                            │
  Host #1  acheron  192.168.1.21   ark@crystalisles   (CrystalIsles)  ◄─────┤
  Host #2  cocytus  192.168.1.22   ark@fjordur        (Fjordur)       ◄─────┘

  Both mount the SAME cluster dir over NFS  ──►  a NAS (NFS server, 192.168.1.15)
     /opt/ark/cluster  =  192.168.1.15:/mnt/tank/ark/cluster
```

One map per box, one shared `CLUSTER_ID`. The **shared NFS cluster directory is
load-bearing**: ARK writes cross-server transfer data to `ARK_ROOT/cluster`, and
on a multi-host cluster that directory must be the same storage on both hosts or
uploads on one map never appear on the other. That's the single thing most
homelab ARK clusters get wrong.

## Layout

```
netboot/                 reusable PXE stack: dnsmasq proxyDHCP + TFTP + HTTP (no USB)
bootstrap/               the Debian 13 preseed (served by netboot) + USB/ISO fallback
ansible.cfg              vault password file, sudo, inventory path
inventory/hosts.yml      the two hosts + each host's ark_instances (map+ports)
group_vars/all.yml       cluster id, appid, NFS + backup targets, hardening
group_vars/vault.yml     ansible-vault: admin/RCON password (gitignored)
site.yml                 the playbook
roles/
  common/                hostname, base pkgs, unattended-upgrades, ufw (game/query UDP; RCON LAN-only)
  ark_deps/              i386 multiarch, steamcmd (non-free), lib32gcc-s1, builds mcrcon
  cluster_mount/         mounts the shared NFS cluster dir
  gamectl/               vendors gamectl, renders /etc/gamectl.conf, install + create + enable units
  ark_backup/            systemd timer -> save-safe gamectl backup -> rsync to TrueNAS
.github/workflows/       GitHub Actions lint (default CI)
ci/                      optional self-hosted Woodpecker stack for Styx
```

## Day 0 — bare metal (over the network, no USB)

The two Tinys install themselves over the wire. A reusable PXE stack on Styx
(`netboot/`) runs `dnsmasq` in **proxyDHCP** mode — it adds PXE boot info without
touching your pfSense DHCP — plus `nginx` to serve the preseed. PXE-boot a Tiny
and it installs Debian 13 unattended, then reboots SSH-ready.

```bash
# fill the SSH key + throwaway password in bootstrap/preseed.cfg first, then:
cd netboot && ./setup.sh && sudo docker compose up -d --build   # config in netboot/.env (cp .env.example .env)
```

Enable network boot in each Tiny's firmware, power on, walk away. Full steps and
troubleshooting in [`netboot/README.md`](netboot/README.md). One generic image;
Ansible assigns `acheron`/`cocytus` from inventory. (A USB/ISO path also exists
in [`bootstrap/README.md`](bootstrap/README.md) if you ever want it.)

## Quickstart

```bash
# 0. collections
ansible-galaxy collection install -r requirements.yml

# 1. environment config (live copies are gitignored)
cp inventory/hosts.example.yml inventory/hosts.yml     # your IPs + ansible_user
cp group_vars/all.example.yml group_vars/all.yml       # NFS/backup/cluster settings
cp netboot/.env.example netboot/.env                   # PXE stack + installer identity

# 2. secrets
cp group_vars/vault.example.yml group_vars/vault.yml
$EDITOR group_vars/vault.yml         # set a strong vault_admin_password
ansible-vault encrypt group_vars/vault.yml
echo 'my-vault-password' > .vault_pass && chmod 600 .vault_pass   # gitignored

# (phase one needs no NAS — cluster NFS + off-box backup default to off
#  in group_vars/all.yml; flip them on later when the exports exist)

# 3. vendor the current gamectl (already fetched, but keep it in sync):
cp ~/utilities/bash-scripts/ark-ase/gamectl roles/gamectl/files/gamectl

# 4. dry run, then deploy
ansible-playbook site.yml --check --diff
ansible-playbook site.yml
```

First run downloads the ~14 GB server template per host (async, 30s poll).
Subsequent runs are fast and idempotent.

## Day-two ops

```bash
ansible-playbook site.yml --tags gamectl -l cocytus   # re-render conf, sync
ansible all -m command -a "gamectl status"            # fleet status
ansible all -m command -a "gamectl update"            # patch template (then sync)
```
RCON, mods, and per-instance control are all `gamectl` on the box; Ansible only
owns provisioning + config + lifecycle timers.

## Router port forwards

Per instance, forward **UDP GamePort and QueryPort** to that host's LAN IP.
Keep **RCON (TCP) off the internet** — it's LAN-only by design.

| Host    | Map          | Game (UDP) | Query (UDP) | RCON (LAN only) |
|---------|--------------|-----------:|------------:|----------------:|
| acheron | CrystalIsles |       7795 |       27060 |           27160 |
| cocytus | Fjordur      |       7799 |       27062 |           27162 |

## CI (lint only — the one justified pipeline)

Push-triggered lint: `yamllint`, `ansible-lint`, and `shellcheck` on the vendored
`gamectl`. No build, because there's nothing to compile.

**This repo lives on self-hosted Gitea, so the default is Gitea Actions.**
Gitea Actions is GitHub-Actions-compatible and picks up the same
`.github/workflows/lint.yml` (shellcheck is installed explicitly in the
workflow, so it runs identically on GitHub-hosted and self-hosted runners).
One-time setup: enable Actions on the Gitea instance (`[actions] ENABLED=true`
in app.ini, or it may already be on), enable Actions on the repo
(Settings -> Actions), and register a runner — a ready `.env`-driven act_runner
stack for Styx is in `ci/gitea-runner/`.

If the repo is ever mirrored/published to GitHub, the same workflow runs there
with zero changes (free on public repos). Woodpecker (`ci/`) remains as a
third option; run one CI, not several.

Linter config (`.yamllint` / `.ansible-lint`) is tuned so the first run flags
real problems, not style nits.
