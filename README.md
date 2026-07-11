# ark-fleet

A fun learning project for testing and practicing **DevOps methodology and
tooling** against a real workload: Infrastructure-as-Code that takes two small
bare-metal hosts from powered-off to a running **ARK: Survival Evolved**
cluster — unattended OS install over PXE, configuration management with
Ansible, lint CI on every push. The game servers are the excuse; the pipeline
is the point.

Built around the [`gamectl`](https://github.com/OzarkMountainPirate/utilities/tree/main/bash-scripts/ark-ase)
toolkit. Ansible is the control plane; `gamectl` + systemd `ark@.service` is the
runtime. No Docker on the game hosts, no daemons, no orchestration server.
**Target OS: Debian 13 (trixie).**

## Why no CI/CD orchestration server?

There is no build here. A game server has no compile step and no artifact to
promote, so a CI/CD orchestrator (Jenkins, GitLab CI runners-as-a-service,
Spinnaker, and friends) would be solving a problem this project doesn't have.
The DevOps value in a workload like this is **reproducibility and configuration
management** — that's Git + Ansible. The one pipeline that earns its keep is
lint-on-push (see "CI" below), and a hosted runner covers it with zero
infrastructure. Picking the smallest tool that does the job is part of the
methodology being practiced.

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
  static_net/            pins each host's IP from the inventory (no DHCP reservations)
  common/                hostname, base pkgs, unattended-upgrades, ufw (game/query UDP; RCON LAN-only)
  data_disk/             optional second disk (e.g. HDD) formatted + mounted at /opt
  ark_deps/              i386 multiarch, steamcmd (non-free), lib32gcc-s1, builds mcrcon
  cluster_mount/         mounts the shared NFS cluster dir
  gamectl/               vendors gamectl, renders /etc/gamectl.conf, install + create + enable units
  ark_backup/            systemd timer -> save-safe gamectl backup -> rsync to TrueNAS
.github/workflows/       GitHub Actions lint CI (yamllint, ansible-lint, shellcheck)
```

## Day 0 — bare metal (over the network, no USB)

The hosts install themselves over the wire. A reusable PXE stack on a LAN Docker host
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
# 0. collections — ONLY needed if you installed bare ansible-core.
#    The full 'ansible' package (apt or pip) already bundles these; skip if so.
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
export ANSIBLE_VAULT_PASSWORD_FILE=$PWD/.vault_pass   # ansible.cfg deliberately
# doesn't reference the file (a missing referenced file breaks CI and fresh
# clones) — set this per shell, or add it to your direnv/.bashrc for the repo

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

## CI (lint on push)

`.github/workflows/lint.yml` runs three linters on every push via GitHub
Actions — no self-hosted infrastructure:

- **yamllint** — catches malformed YAML (bad indentation, duplicate keys,
  syntax slips) across the whole repo before Ansible ever parses it.
- **ansible-lint** — checks the playbook and roles against Ansible best
  practices: deprecated syntax, unsafe patterns, idempotency smells, naming
  conventions. Config in `.ansible-lint`, with each skipped rule justified
  inline.
- **shellcheck** — static analysis for the shell scripts (`netboot/setup.sh`,
  `bootstrap/build-iso.sh`, the vendored `gamectl`): quoting bugs, unset
  variables, portability traps. Config in `.shellcheckrc`.

There's nothing to compile, so lint IS the test suite: it can't prove a deploy
will succeed, but it catches the class of typo that would otherwise only
surface mid-playbook-run against a live host. Red X on a commit = don't deploy
that commit.
