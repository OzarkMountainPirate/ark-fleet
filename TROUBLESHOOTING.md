# Troubleshooting

Every failure mode in here was hit for real. The commands are the ones that
actually distinguished causes, in the order worth running them.

## First: look at every host

```bash
ansible ark_fleet -a "gamectl status"
```

```
INSTANCE         MAP            GAME     QUERY    STATE        RESTARTS  SINCE
ragnarok         Ragnarok       7791     27058    active       43        Thu 04:01:05 CDT
```

`STATE` alone lies. A crash-looping instance reports `active` or `activating`
between deaths, so it looks healthy in any check that only reads state. The
signal is **RESTARTS climbing** with a **SINCE of seconds ago** — that is a
crash loop, and `NRestarts` counts only automatic restarts, so a nonzero value
means the server died on its own.

**Check both hosts, every time.** Identical config on identical hardware
diverges more often than intuition suggests — different maps, different saves,
different memory. Diagnosing one host and generalising to the fleet wastes
hours. If one host is fine and the other is not, that asymmetry is the single
most valuable clue available: whatever differs between them is the cause.

## Reading the exit

```bash
ansible ark_fleet -m shell -a "journalctl -u 'ark@*' --no-pager -n 30"
```

| Exit | Meaning |
|------|---------|
| `status=11/SEGV` + `Signal 11 caught` | Real crash. Look at the line above it. |
| `status=6/ABRT` next to `Stopping`/`Stopped` | **Normal.** ARK aborts on deliberate shutdown instead of exiting cleanly. Not a fault. |
| `status=9/KILL` | Killed from outside — usually the OOM killer. Confirm below. |

```bash
ansible ark_fleet -m shell -a "journalctl -k --no-pager | grep -iE 'out of memory|killed process' | tail -3"
```

Empty output means memory was not the cause, whatever the peak figures say.

## Content corruption: `Bad name index`

```
LowLevelFatalError [File:...LinkerLoad.cpp] [Line: 3921]
Bad name index 1334676658/120
Signal 11 caught.
```

SEGV roughly 25–30s into startup, an empty `ShooterGame.log` (the crash
precedes logging), and a memory peak far below a healthy load. The engine is
deserializing a package whose name table does not contain the referenced
index. Causes, in the order they are worth checking:

1. **A mod was removed from a world that used it.** A save containing
   entities or structures from a mod cannot load once that mod is gone.
   This is the most common cause and it is not a bug — it is how ARK works.
   Fix: wipe `SavedArks` (below).
2. **Undeclared mods left on disk.** Mods present in `Content/Mods` but not in
   `ActiveMods` can still break the load. `gamectl mods` prunes anything not
   declared, so a run of the play resolves it.
3. **Content extracted from the wrong cook.** ASE dedicated servers load
   **Windows**-cooked mod packages even on Linux. Extracting `LinuxNoEditor`
   yields this exact crash for every mod, with a byte-identical index. Fixed
   in gamectl 1.5.5; `MOD_BRANCH` exists if you ever need to override it.

**An identical index across different mods, different maps, and different
hosts means a common artifact — the pipeline, not the content.** Different
mods failing for their own reasons would fail at different indices.

## Getting back to a known-good state

The single most useful move when several things have been changed at once is
to stop bisecting and re-establish a floor. Every diagnosis rests on having
one.

```bash
# 1. declare vanilla
$EDITOR group_vars/all/main.yml     # mods: []
ansible-playbook site.yml           # prunes every workshop mod from disk

# 2. fresh worlds
ansible ark_fleet -a "gamectl stop all"
ansible ark_fleet -m shell -a "rm -rf /opt/ark/instances/*/ShooterGame/Saved/SavedArks"
ansible ark_fleet -a "gamectl start all"

# 3. verify the floor
sleep 240 && ansible ark_fleet -a "gamectl status"      # RESTARTS 0 on every host
ansible ark_fleet -m shell -a "ls /opt/ark/instances/*/ShooterGame/Content/Mods/*.mod | wc -l"   # 1
```

That `1` is the stock `111111111.mod`. If vanilla with no mods on disk and
fresh saves still crashes, the fault is in the base install, not the mods —
run `gamectl update` to make steamcmd re-validate the template.

Add mods back **additively** from there, in as few steps as possible, checking
both hosts between them. Adding is safe; removing is destructive.

## Bisecting a mod list quickly

A full `site.yml` run per test is minutes. Since the mods are already on disk,
`ActiveMods` alone decides what loads — that is a ~60 second loop on one host:

```bash
test_mods() {   # usage: test_mods 1999447172,2228125546
  ansible acheron -a "gamectl stop ragnarok"
  ansible acheron -m shell -a "sed -i 's/^ActiveMods=.*/ActiveMods=$1/' \
    /opt/ark/instances/ragnarok/ShooterGame/Saved/Config/LinuxServer/GameUserSettings.ini"
  ansible acheron -m shell -a "rm -rf /opt/ark/instances/ragnarok/ShooterGame/Saved/SavedArks"
  ansible acheron -a "gamectl start ragnarok"
  sleep 75
  ansible acheron -m shell -a "journalctl -u ark@ragnarok -n 6 --no-pager"
}
```

Edit `ActiveMods` **after** stopping — ARK rewrites `GameUserSettings.ini` on
shutdown and will clobber a live edit. Wipe the save each round or you are
testing the previous round's corruption. When you find the answer, put it in
`group_vars` and run the play; nothing here is a substitute for declared state.

## Verifying a mod install

```bash
# what is actually on disk vs what is declared
ansible ark_fleet -m shell -a "ls /opt/ark/instances/*/ShooterGame/Content/Mods/*.mod | wc -l"
ansible ark_fleet -m shell -a "grep ActiveMods /opt/ark/instances/*/ShooterGame/Saved/Config/LinuxServer/GameUserSettings.ini"
```

Expect `declared mods + 1` for the `.mod` count (the extra is stock
`111111111.mod`). `gamectl mods` logs which cook each mod came from
(`source WindowsNoEditor`) and verifies every extracted file against the
`.uncompressed_size` sidecars the Workshop ships; a mod that fails extraction
is reported and **not** installed, rather than left half-written.

## Servers missing from the Steam list

Not an error state — servers are invisible until fully loaded, and a first
boot with large mods on spinning disks takes far longer than it feels like it
should. Check whether the query port is bound yet:

```bash
ansible ark_fleet -m shell -a "ss -ulpn | grep -E '27058|27062' || echo 'not listening yet'"
```

If the port is bound and the server still does not appear, the cause is almost
certainly a **branch mismatch**: client and server major versions must match,
and mismatched servers are silently hidden rather than shown with an error.
See `ark_branch` in the README.

## Memory

```bash
ansible ark_fleet -m shell -a "systemctl show -p MemoryPeak --value 'ark@*.service'; free -h"
```

Read peaks from a **long-running** process; a crashing server's peak is
meaningless. A vanilla ASE instance settles around 6–8 GB after a few hours,
and mods add to that. Swap traffic matters more than swap usage — a few
hundred MB parked in swap is harmless, sustained paging is not:

```bash
ansible cocytus -m shell -a "vmstat 5 6"     # watch si/so during play
```

## Operational traps

- **Never Ctrl-C an async Ansible task and immediately re-run it.** The remote
  job survives the interrupt. Two concurrent `gamectl mods` runs will delete
  each other's temp files mid-extract. `gamectl` takes a lock to prevent this,
  but check for survivors before assuming:
  `ansible ark_fleet -m shell -a "pgrep -af 'gamectl|steamcmd'"`
- **`gamectl sync` refuses to touch a running instance** and exits nonzero.
  That is deliberate — rsync under a live server corrupts it. Stop first.
- **ARK rewrites its own config files on shutdown.** `GameUserSettings.ini`
  and `Game.ini` are both normalised by the engine, so anything written to
  them while a server is running is provisional. The play accounts for this;
  hand edits should be made with the instance stopped.
