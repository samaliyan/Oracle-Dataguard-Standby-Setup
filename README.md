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

## Download

Take `dg_standby_setup-<version>.sh` from the latest release on the
[Releases](../../releases) page (each release also has a `.sha256` checksum), and rename it to
`dg_standby_setup.sh` if you like. What changed in each version: [CHANGELOG.md](CHANGELOG.md).

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

## Command reference

Run every command as `root` on the **standby** server. Only one run at a time is possible (a lock).
None of them changes the primary.

| Command | In short |
|---|---|
| `./dg_standby_setup.sh` | Menu: full setup or one part; continues where the last run stopped |
| `--check` | Look and report only; changes nothing |
| `--primary <ip>` / `--user <name>` | Primary address and its ssh user, without being asked |
| `--from <step>` | Continue from one step |
| `--only <part>` | One phase, part or step range, then stop |
| `--yes` | Do the actions on this server without the [y] question (the risky ones are still asked) |
| `--settings` | Review or edit the saved values, then stop |
| `--status` | Result of every phase and step so far; connects to nothing |
| `--show-changes [step]` | Every change made on this server, with its undo |
| `--undo <step>` | Undo the changes of one step |
| `--help-step <step>` | The manual way of a step (`all` for every step, `health` for --health) |
| `--health` | Unattended health check for cron or monitoring (exit 0/1/2/3) |
| `--roll-forward` | Bring a standby that cannot catch up up to date from the primary (18c+) |
| `-h`, `--help` | Short help |

### `./dg_standby_setup.sh` (no option)
Opens a menu: the full setup, or one part (OS preparation, Grid, database software, the primary changes,
chosen steps, the daily check). On a later run it continues where it stopped; done steps are only
checked again. Each step shows what it found and what it will do, then asks
`[y] Yes, do it  [s] Skip  [h] Help  [q] Quit`. Commands for the primary are shown; you run them there
and answer `r`, and the script checks the result.

### `--check`
Runs every check and reports what is missing, without changing anything in Oracle, the OS or the primary,
and without touching the saved progress. It still asks for the ssh and sys passwords (to read the primary).
Start with it on a new server.

### `--primary <ip>` and `--user <name>`
Give the primary's IP address or host name and the OS user for ssh there (default `oracle`, never `root`),
so the first questions are not asked. Example: `./dg_standby_setup.sh --primary 10.0.0.5 --user oracle`.

### `--from <step>`
Starts at a step, for example `--from 6.1`, and goes on to the end. Phase 1 (connection and settings)
always runs first. Step 10.7 is only reachable with `--roll-forward`.

### `--only <part>`
Runs one part and stops after its last step. Phase 1 runs first, so the primary must be reachable.
- a phase: `--only 4` (the changes on the primary, can be done early), `--only 10` (the health check)
- a part: `os` (phase 2), `grid` (3.1-3.5), `db` (3.6-3.11), `primary` (phase 4)
- steps: `--only 3.6`, `--only 2.1-2.4`, `--only 2-3`

### `--yes`
Answers `y` for the actions on this server. Still asked, every time: erasing disks, moving leftovers
aside, a half-unpacked software folder, the RMAN copy (the word `DUPLICATE`), the primary's host key,
passwords, the listener restart (3.10), the standby restart steps (9.1, 9.2, 9.3, 9.7) and the deletion
setting of archived logs (9.8). Typical use: `--check` first, put the installer zips in place, then `--yes`.

### `--settings`
Shows the saved standby values (names, folders, disk groups, channels, `HEALTH_LAG_MAX`,
`DUP_SECTION_SIZE` and so on) and lets you edit them in `$EDITOR`, then stops. Changed values are checked
and must be accepted again on the next run.

### `--status`
Prints the result of every phase and step from the saved progress (ok, done, waiting, failed, skipped).
Connects to nothing, so it also works when the primary is down.

### `--show-changes [step]`
Lists every change the script made on this server (files written, settings, users, disks, services,
database changes), each with how it is undone. With a step number, only that step: `--show-changes 6.1`.

### `--undo <step>`
Undoes the changes of one step, newest first, and asks before each one. A file is restored only when it
is still what the script wrote; something that may hold data is never removed. Changes on the primary are
shown for you to undo there.

### `--help-step <step>`
How to do a step by hand: where, as which user, the commands, the expected result. `--help-step all`
prints every step; `--help-step health` explains `--health`. The commands use your saved names.

### `--health`
The checks of phase 10 for cron or a monitoring agent: no questions, no changes, no terminal needed.
Checks, in this order: the standby instance (down is CRITICAL at once), 10.1 transport and apply lag
(and whether data from the primary still arrives), 10.2 archive gap (and whether missing logs are still on
the primary), 10.3 last log on both sides, 10.4 redo apply and real-time apply, 10.5 NOLOGGING blocks,
10.6 patch level of both database homes. A problem in 10.1-10.4 is checked once more after 60 seconds.
Prints one line per check; details go to `health_<time>.log` (14 days, at most 500 files).
Exit code: `0` OK, `1` WARNING, `2` CRITICAL, `3` UNKNOWN (could not check, another run active, after a
switchover, or a wrong option). The checks on the primary need an ssh key of root (see below).

### `--roll-forward`
For a standby that cannot catch up (archived logs it needs were deleted on the primary) or after
NOLOGGING work: runs `RECOVER STANDBY DATABASE FROM SERVICE` (18c and later) instead of a new copy.
Asks for the sys password and the word `ROLLFORWARD`; never runs with `--yes` or `--check`.
Checks first, and stops on any doubt: standby mounted, no RMAN session or long job running, broker off,
static listener entry, auto-login wallet for an encrypted standby, both RMAN logins, and that RMAN can
find the standby's datafiles again. Afterwards it sets the standby redo logs and RMAN settings again and
starts redo apply. If the terminal closes meanwhile, the next `--roll-forward` checks and finishes it
without running RMAN again. On 12.1/12.2 it shows the manual way.

### Settings that change behaviour
- `HEALTH_LAG_MAX`: lag in seconds that `--health` accepts (empty = 300, at least 30).
- `DUP_SECTION_SIZE`: section size of the RMAN copy, for example `32G`. Empty = automatic (32G when a
  datafile is 64 GB or more and there is more than one channel; needs COMPATIBLE 12.0+), `0` = never.
- `AUX_CHANNELS`: channels of the RMAN copy.

### Exit codes
`0` every step OK; `1` stopped, or some steps are not OK or skipped (normal for `--check` on a new
server); `2` wrong option or unknown step. With `--health`: `0` OK, `1` WARNING, `2` CRITICAL, `3` UNKNOWN.

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
src/                  source, split by phase; build.sh joins them in a fixed order
build.sh              rebuilds dg_standby_setup.sh from src/
CHANGELOG.md          what changed in each version
.github/workflows/    makes the release of each new version by itself (script, checksum, notes)
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
