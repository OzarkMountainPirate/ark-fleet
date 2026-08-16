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

```text
        Router/firewall (192.168.1.1)       ── port-forwards game+query UDP ──┐
                                                                            │
  Host #1  acheron  192.168.1.21   ark@ragnarok       (Ragnarok)      ◄─────┤
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

```text
netboot/                 reusable PXE stack: dnsmasq proxyDHCP + TFTP + HTTP (no USB)
bootstrap/               the Debian 13 preseed (served by netboot) + USB/ISO fallback
ansible.cfg              sudo, inventory path (NO vault password file — see quickstart step 2)
inventory/hosts.yml      the hosts + each host's ark_maps (ports derive from ark_port_map)
group_vars/all/          live config dir: main.yml (settings) + vault.yml (secrets)
group_vars/*.example.yml committed templates for the files in group_vars/all/
site.yml                 the playbook
requirements.yml         galaxy collections (quickstart step 0)
host_vars/               optional per-host overrides
TROUBLESHOOTING.md       symptom -> cause -> fix
check-docs.py            documentation drift check (run by CI)
roles/
  static_net/            pins each host's IP from the inventory (no DHCP reservations)
  common/                hostname, base pkgs, unattended-upgrades, ufw (game/query UDP; RCON LAN-only)
  data_disk/             optional second disk (e.g. HDD) formatted + mounted at /opt
  ark_deps/              i386 multiarch, steamcmd (non-free), lib32gcc-s1, builds mcrcon
  cluster_mount/         mounts the shared NFS cluster dir
  gamectl/               fetches gamectl from upstream at a pinned ref, renders /etc/gamectl.conf, install + create + enable units
  ark_backup/            systemd timer -> save-safe gamectl backup -> rsync to the NAS
  ark_update/            Sunday maintenance: RCON countdown -> update -> patch -> reboot if needed
  nas_ark_exports/       TrueNAS play: datasets, squash identity, LAN-only NFS exports
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
# 0. collections — always run this. The full 'ansible' package bundles
#    community.general and ansible.posix, but NOT arensb.truenas, which the
#    nas_ark_exports play needs. (See .github/workflows/lint.yml, which
#    installs it separately for the same reason.)
ansible-galaxy collection install -r requirements.yml

# 1. environment config (live copies are gitignored)
mkdir -p group_vars/all
cp inventory/hosts.example.yml inventory/hosts.yml       # your IPs + ansible_user
cp group_vars/all.example.yml group_vars/all/main.yml    # maps, rates, mods, NAS
cp netboot/.env.example netboot/.env                     # PXE stack + installer identity

# 2. secrets
cp group_vars/vault.example.yml group_vars/all/vault.yml
$EDITOR group_vars/all/vault.yml     # set a strong vault_admin_password
ansible-vault encrypt group_vars/all/vault.yml
echo 'my-vault-password' > .vault_pass && chmod 600 .vault_pass   # gitignored
export ANSIBLE_VAULT_PASSWORD_FILE=$PWD/.vault_pass   # ansible.cfg deliberately
# doesn't reference the file (a missing referenced file breaks CI and fresh
# clones) — set this per shell, or add it to your direnv/.bashrc for the repo

# (no NAS yet? cluster NFS + off-box backup can be left off in
#  group_vars/all/main.yml and flipped on once the exports exist)

# 3. gamectl deploys from its upstream repo at the ref pinned in group_vars
#    (gamectl_version). Updating gamectl = commit upstream, bump the pin here.

# 4. dry run, then deploy
ansible-playbook site.yml --check --diff
ansible-playbook site.yml
```

First run downloads the ~14 GB server template per host (async, 30s poll).
Subsequent runs are fast and idempotent.

## Day-two ops

```bash
ansible-playbook site.yml --tags gamectl -l cocytus     # re-render conf, sync
ansible ark_fleet -a "gamectl status"                  # fleet status + restart counts
ansible ark_fleet -a "gamectl stop all"                # then update, then sync
ansible ark_fleet -B 7200 -P 60 -a "gamectl update"    # patch template (long)
```

RCON, mods, and per-instance control are all `gamectl` on the box; Ansible only
owns provisioning + config + lifecycle timers.

## Maps, scaling, and mods

Ports are a function of the map (`ark_port_map` in group_vars), so the
inventory only declares which maps each host runs:

```yaml
acheron:
  ark_maps: [Ragnarok, Valguero]
```

- **Add a map:** add its name, run the play. Instance is created from the
  local template (fast — no re-download), unit enabled, firewall opened.
- **Remove a map:** delete its name, run the play. The play retires the
  instance: save-safe `gamectl backup` first, then stop/disable, then the
  instance directory is removed (only if the backup succeeded;
  `ark_retire_removes_data: false` keeps data on disk instead).
- **Swap a map:** both of the above in one edit + one run.
- **Rates (the boosted-server dial):** `ark_rate_multiplier: 1000` turns the
  cluster into what an advertised 1000x server actually runs — the dial drives
  a curve (`ark_rate_profile` in the gamectl role), not a blind constant:
  linear knobs cap (harvest 500, loot quality 5, imprint 100 so one cuddle =
  full imprint), interval knobs invert (mating/cuddle floors at 0.01), and
  difficulty snaps to wild-150 (override to 10.0 for wild-300). `ark_rates`
  overrides any single knob without touching the rest. GameUserSettings-class
  values ship as launch options (immune to ARK's INI rewriting); breeding and
  loot knobs render into each instance's Game.ini. Changes restart the
  instances automatically. After raising difficulty, run
  `gamectl rcon <instance> "DestroyWildDinos"` once per map.
- **Steam beta branch:** `ark_branch` in group_vars pins the server files to a
  Steam branch (e.g. `preaquatica` for pre-Aquatica 358.x — required when
  players run the preaquatica/linuxnative client branches; live-branch servers
  are silently HIDDEN from them). The play records the deployed branch in
  `{{ ark_root }}/.deployed_branch` and, on drift, applies the change itself:
  stop -> re-download on the new branch (large) -> sync -> start. **Saves do
  not survive a branch rollback** — wipe `SavedArks` and the cluster dir after
  moving to an older branch. Client and server major versions must match.
- **Level caps:** `ark_player_max_level` / `ark_dino_max_level` regenerate the
  `LevelExperienceRampOverrides` ramps and the per-level engram lines in
  `Game.ini`. ARK identifies the two ramps **by position, not by name** — first
  is players, second is tamed dinos — so the template's ordering is
  load-bearing. Budget headroom: ascension and chibi levels stack on top of the
  cap. Wild dino levels are a different setting entirely
  (`OverrideOfficialDifficulty` x 30, via `ark_rates`).
- **Mods:** the global `mods` list declares Workshop IDs (order = load order).
  The play pre-installs them into the template via `gamectl mods` — steamcmd
  download, `.z` extraction, `.mod` generation (ported from ark-server-tools) —
  because the engine's own `-automanagedmods` SEGVs on modern Linux. Mods
  update ONLY during the Sunday maintenance window (`gamectl mods force`),
  never on ordinary boots, so a mod author's bad Tuesday can't take the
  cluster down until you let it.
  Removing an ID from the list PRUNES that mod from disk on the next run
  (declared state is truth), then syncs and restarts.
  **Adding mods is safe; REMOVING them is destructive.** A save that contains
  entities or structures from a mod cannot load once that mod is gone — the
  server dies deserializing the world (`Bad name index` in `LinkerLoad`,
  SEGV ~25s in, empty ShooterGame.log). Recovery is a `SavedArks` wipe. So do
  not bisect a mod list against a world you care about: settle the list, then
  start the world. Check BOTH hosts after any mod change — `gamectl status`
  reports restart count and last-start time precisely because a crash-looping
  instance still prints "active" between deaths.

Retired maps' ufw rules are not auto-removed (harmless on LAN; prune with
`ufw status numbered` if desired). Router port forwards are manual either way.

## Common operations

```bash
# add a map            edit ark_maps in inventory, then:
ansible-playbook site.yml

# turn the cluster into a 300x server
$EDITOR group_vars/all/main.yml         # ark_rate_multiplier: 300
ansible-playbook site.yml
ansible acheron -a 'gamectl rcon ragnarok "DestroyWildDinos"'   # per map, if difficulty changed

# raise the level cap (players to 205, tamed dinos to 450)
$EDITOR group_vars/all/main.yml         # ark_player_max_level / ark_dino_max_level
ansible-playbook site.yml               # regenerates Game.ini, restarts

# add mods (safe) — order in the list IS load order
$EDITOR group_vars/all/main.yml         # mods: [839162288, ...]
ansible-playbook site.yml               # downloads can take a long while
ansible ark_fleet -a "gamectl status"   # RESTARTS must stay 0, on BOTH hosts

# remove mods (destructive to existing saves — see TROUBLESHOOTING.md)
$EDITOR group_vars/all/main.yml
ansible-playbook site.yml               # prunes from disk, syncs, restarts

# run the weekly maintenance window by hand (broadcasts a countdown in-game)
ansible acheron -a "systemctl start ark-maintenance.service"

# force a backup now, and check it landed off-box
ansible acheron -a "systemctl start ark-backup.service"
ssh root@<nas> ls -la /mnt/<pool>/ark/backups/acheron/

# verify the deployed toolkit matches the pin
ansible ark_fleet -a "gamectl version"
```

A plain `ansible-playbook site.yml` with nothing changed is a no-op: zero
changed tasks, no handlers, no restarts. If a run reports changes when you
changed nothing, that is a bug worth chasing — it means something is rewriting
managed state behind the play.

## When something breaks

See **[TROUBLESHOOTING.md](TROUBLESHOOTING.md)** — crash loops, `Bad name
index` corruption, mod bisection, getting back to a known-good baseline, and
how to read ARK's exit signals (`ABRT` on a clean shutdown is normal;
`SEGV` is not).

## Router port forwards

Per instance, forward **UDP GamePort and QueryPort** to that host's LAN IP.
Keep **RCON (TCP) off the internet** — it's LAN-only by design.

| Host    | Map          | Game (UDP) | Query (UDP) | RCON (LAN only) |
|---------|--------------|-----------:|------------:|----------------:|
| acheron | Ragnarok     |       7791 |       27058 |           27158 |
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
  `bootstrap/build-iso.sh`): quoting bugs, unset variables, portability traps.
  Config in `.shellcheckrc`. `gamectl` itself is not vendored here — it is
  fetched at a pinned tag and checksum-verified at deploy time, and linted in
  its own repo.

There's nothing to compile, so lint IS the test suite: it can't prove a deploy
will succeed, but it catches the class of typo that would otherwise only
surface mid-playbook-run against a live host. Red X on a commit = don't deploy
that commit.
