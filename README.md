# dg_standby_setup.sh

**[فارسی](README.fa.md)**

One Bash script that builds an **Oracle Data Guard physical standby**, step by step, on a new server.
It runs on the standby server and copies the database with RMAN active duplicate.

**The primary is never changed by the script.** On the primary it only runs a fixed set of read-only
checks and `SELECT` statements. Anything that has to change on the primary is printed for the DBA,
together with its undo command. The script then checks the result, again read-only.

## Supported

| | |
|---|---|
| Oracle Database | 12.1, 12.2, 18c, 19c, 21c, 23ai. CDB or non-CDB, single-instance primary |
| Standby OS | Oracle Linux 7, 8, 9 (bash 4.2 and later) |
| Primary storage | ASM, file system, or both |
| Grid Infrastructure | Oracle Restart on the standby when the primary uses ASM. Owned by a separate `grid` user or by `oracle` |

## Quick start

Copy the script to the **standby** server and run it as `root`:

```bash
chmod 750 dg_standby_setup.sh
./dg_standby_setup.sh --check            # look only; changes nothing in Oracle, the OS or the primary
./dg_standby_setup.sh                    # build the standby
```

On the first connection the script shows the ssh host key fingerprints of the primary. Compare them with
the output of this command on the primary, as root, before you answer `y`:

```bash
for f in /etc/ssh/ssh_host_*_key.pub; do ssh-keygen -lf "$f"; done
```

Run without options, the script first shows a menu: the full setup, or one part only (OS preparation,
Grid, the database software, the primary changes, chosen steps, the daily check). It stops after the last
step of that part. The same parts work from the command line:

```bash
./dg_standby_setup.sh --only os          # phase 2
./dg_standby_setup.sh --only grid        # steps 3.1 - 3.5
./dg_standby_setup.sh --only db          # steps 3.6 - 3.11
./dg_standby_setup.sh --only 2.1-2.4     # chosen steps
```

Before each step the script shows what it found and what it will do, and asks:

```
[y] Yes, do it   [s] Skip   [h] Help   [q] Quit
```

## Phases

| Phase | What happens |
|---|---|
| 1 | Connect to the primary over ssh and read its configuration |
| 2 | OS: packages, kernel settings, users, limits, disks, and enough memory (RAM, /dev/shm) for the SGA and PGA of the primary |
| 3 | Install the Oracle software (and Grid if ASM is used) and patches |
| 4 | Primary readiness: force logging, standby redo logs, archive settings (**printed** for the DBA) |
| 5 | Network files (listener, tnsnames) |
| 6 | Password file and TDE wallet |
| 7 | Start the standby instance in NOMOUNT and test all four logins |
| 8 | RMAN active duplicate |
| 9 | Register with Oracle Restart, start redo apply and redo shipping, start at boot, archive log clean-up |
| 10 | Check: lag (and whether data still arrives), gaps, redo apply, NOLOGGING blocks, patch level; known errors explained (daily, or unattended with `--health`) |

Phase 4 can be done first, to batch all primary changes into one maintenance window:

```bash
./dg_standby_setup.sh --only 4
```

## Options

```
--primary <ip>        primary IP or host name
--user <name>         ssh user on the primary (default oracle, never root)
--check               report only; changes nothing in Oracle, the OS or the primary
--from <step>         continue from a step
--only <part>         run one part, then stop: a phase (10 = health check), os, grid, db, primary,
                      or steps such as 2.1-2.4 (phase 1 runs first, so the primary must be reachable)
--health              unattended health check (cron, monitoring): no questions, no changes, one line per
                      check; exit 0 OK, 1 WARNING, 2 CRITICAL, 3 UNKNOWN
--roll-forward        bring a standby that cannot catch up up to date from the primary with RMAN
                      (18c and later), instead of a new copy
--settings            review or edit the saved standby values
--yes                 answer y for the actions on this server; disk erasure, clean-up, the copy, the
                      host key, passwords, the listener restart (3.10), the restart steps (9.1-9.3,
                      9.7) and the deletion setting of archived logs (9.8) are still asked
--status              result of every phase and step so far (connects to nothing)
--show-changes [step] every change made on this server, with its undo
--undo <step>         undo the changes of a step (asks before each one)
--help-step <step>    the manual commands of a step ("all" for every step)
```

## Daily check from cron

```bash
# root's crontab on the standby
17 6 * * *  /root/dg_standby_setup.sh --health >/dev/null || /usr/local/bin/my-alert "Data Guard standby needs attention"
```

The checks on the primary need ssh with a key of root (no password can be typed from cron); without it the
local checks still run and the others show UNKNOWN. A restricted key is best, for example in
`~/.ssh/authorized_keys` of the oracle user on the primary:
`from="<standby address>",no-pty,no-port-forwarding ssh-ed25519 AAAA...`.
Details are in `/var/log/dg_standby_setup/health_<time>.log` (kept 14 days, at most 500 files). A problem in
the lag, gap, last-log or apply check is checked once more after 60 seconds before it is reported.
HEALTH_LAG_MAX in the settings sets the accepted lag (300 seconds by default, at least 30).

## When the standby cannot catch up

If archived logs the standby needs were deleted on the primary, step 10.2 says so and names two ways: restore
them on the primary from its backup, or (18c and later) `./dg_standby_setup.sh --roll-forward`. That runs
`RECOVER STANDBY DATABASE FROM SERVICE`: the standby fetches only what it misses, as incremental backups.
Before it starts, the script checks that the standby is mounted, that RMAN can find the standby's files again
afterwards, that no other RMAN session or long job runs, that the broker is off, that the listener has a
static entry for the standby, that an encrypted standby has an auto-login wallet, and that both RMAN logins
work. Afterwards it sets the standby's own standby redo logs and RMAN settings again and starts redo apply.
Try it once on a test standby before you need it.

## Safety design

- **Primary is read-only.** Only whitelisted probes and `SELECT` statements go to the primary.
- **No data is erased without proof.** A disk is used only after it is shown to be empty and not shared with
  the primary. A check that times out counts as "no".
- **Every change can be undone.** Every change on the standby is recorded in a journal
  (`/var/lib/dg_standby_setup/changes.log`) and can be undone one step at a time.
- **Known primary only.** ssh accepts only a host key the admin has checked; a changed key stops the connection.
- **Passwords** never appear in logs, in the process list, or in files that are left behind.
- **Long jobs** (installers, root scripts, the RMAN copy) run in their own session. If the terminal closes,
  they keep running, and the next run of the script waits for them.
- **Never a false ok.** A step that could not be checked (database down, no access, no answer) is shown as
  `waiting`, `problem` or `skipped (optional)`, never as `ok`.
- **Always shows where you are.** Every run starts with a progress board and ends with one "Next" line.

Files:

```
/var/lib/dg_standby_setup/   settings.conf, progress, changes.log
/var/log/dg_standby_setup/   run logs, the commands shown to you, RMAN and installer output
```

## Repository layout

```
dg_standby_setup.sh   the ready-to-use script (built from src/)
src/                  source, split by phase; concatenated in file-name order
build.sh              rebuilds dg_standby_setup.sh from src/
test/                 scenario tests against mock Oracle, ssh, installers and OS tools
docs/DESIGN.md        design notes
```

## Tests

`test/run_scenarios.sh` runs over 520 scenarios against mocks of the primary, the standby, sqlplus/RMAN,
ssh and the installers. These include ASM and file system storage, interrupted jobs, a wrong password,
a disk that is not empty, a failed duplicate, undo, and a check that no changing command ever reaches the primary.

> The tests need root and change `/etc/hosts`. Run them **only in a throw-away container or VM**, never on
> a real server.

```bash
./build.sh
cd test && ./run_scenarios.sh
```

The mocks are not real Oracle. Before using the script in production, run `--check` on the real servers
and read what it reports.

## Disclaimer

Provided as-is, without warranty. Test it in a non-production environment first, and keep a verified
backup of the primary.
