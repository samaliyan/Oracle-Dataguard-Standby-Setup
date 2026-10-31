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

Before each step the script shows what it found and what it will do, and asks:

```
[y] do it   [s] skip (I do it myself)   [h] help   [q] quit
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
| 10 | Check: transport and apply lag, errors (can be run daily) |

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
--only <phase>        run one phase (10 = daily sync check; phase 1 runs first, so the primary must be reachable)
--settings            review or edit the saved standby values
--status              result of every phase and step so far (connects to nothing)
--show-changes [step] every change made on this server, with its undo
--undo <step>         undo the changes of a step (asks before each one)
--help-step <step>    the manual commands of a step ("all" for every step)
```

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

`test/run_scenarios.sh` runs over 350 scenarios against mocks of the primary, the standby, sqlplus/RMAN,
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
