# dg_standby_setup.sh

**[فارسی](README.fa.md)**

One Bash script that builds an **Oracle Data Guard physical standby**, step by step, on a new server.
It runs on the standby server and copies the database with RMAN active duplicate.

**The primary is never changed by the script on its own.** On the primary it only runs a fixed set of
read-only checks and `SELECT` statements. Anything that has to change on the primary is printed for the DBA,
together with its undo command. The script then checks the result, again read-only. Only if you set
`PRIMARY_RUN=yes` may a primary step offer to run its statements over ssh, after you answer `y`, and only
statements of a fixed list (Data Guard parameters, force logging, standby logs): never a restart, a stop, a
deletion, a password change or a file.

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
| 9 | Register with Oracle Restart, start redo apply and redo shipping, start at boot, archive log clean-up, and (optional, 9.9) the ssh key that `--health` uses for the primary |
| 10 | Check: lag (and whether data still arrives), gaps, redo apply, NOLOGGING blocks, patch level; known errors explained. At the end: role, open mode, protection mode, apply, lag and the last applied log. Daily: `--health` from cron (needs the 9.9 key for the primary checks), or `--only 10` by hand |

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
| `--status` | Data Guard state, then the result of every phase and step so far, with the runs and their logs |
| `--plain` | Plain scrolling output instead of the screen layout |
| `--verbose` | Every step in full with the read-only queries it runs and their answers; the full table at the end; with `--health`, the queries under each check (also `DG_VERBOSE=1`) |
| `--show-changes [step]` | Every change made on this server, with its undo |
| `--undo <step>` | Undo the changes of one step |
| `--help-step <step>` | The manual way of a step (`all` for every step, `health` for --health) |
| `--health` | Unattended health check for cron or monitoring (first line = status, exit 0/1/2/3) |
| `--roll-forward` | Bring a standby that cannot catch up up to date from the primary (18c+) |
| `-h`, `--help` | Short help |

### `./dg_standby_setup.sh` (no option)
Opens a menu in three groups (Setup, After setup, Information), with the matching option of each item in
grey: the full setup, check only, one part, start from a step, the health check, roll forward, status,
changes and undo, the manual way of a step, settings. On a later run it continues where it stopped; done
steps are only checked again.

After phase 1 has read both servers, one **summary screen** shows what was found on the primary and here,
where each kind of file of the standby goes, the plan, the problems found now (each with what happens or
what you do), and the values of this run, numbered: `[Enter] Start  [number] Change  [d] Details
[e] Edit the file  [h] Help  [q] Quit`. A number asks only that value and saves it as the new default.

Each step shows what it found and the exact commands it will run (**Will run**, with the OS user and the
environment), then asks `[y] Yes, do it  [a] Yes to all  [s] Skip  [h] Help  [q] Quit`. While it runs,
each command is shown as `Running as grid: ...`; the log has the full command lines. Commands for you are
real commands with the real values; long ones are put into a short script file under `/root/dg` that you
run with one short line (useful in a console where you cannot paste).

### The screen
In a terminal of at least 80 x 24 the top of the screen is a fixed map: every phase with its steps done
out of all, the current one marked, and the totals (done, need attention, to go). Below it only the
current step is shown, with the steps of the same phase done before it as one line each (warnings under
them). A new attempt of a step starts on a clean area. Installers, root scripts and the RMAN copy show
one live line (what runs, for how long); their output stays in its file.

At any question: `l` lists every step with its result and time (type a step number for its details),
`d` shows the details of the current step (what was checked, done and shown, from the log), `h` its help.
These open on a separate screen; closing it returns to the step as it was. While a long job runs, `l` and
`d` (its output so far) work too. A smaller terminal, `--plain`, and `--health` use plain scrolling output.

### `--check`
Runs every check and reports what is missing, without changing anything in Oracle, the OS or the primary,
and without touching the saved progress. It still asks for the ssh and sys passwords (to read the primary).
It does not measure the network speed (that test sends 64 MB from the primary); a normal run does, before the
copy. Start with it on a new server.

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

### Installer files
Put the Grid and database installer zips next to the script (or in /stage, /software, /install, /u01, /opt,
/root, /home, /tmp, /mnt, /media; up to three folder levels down). The script finds them itself:
- The release is read from the Oracle file name (`LINUX.X64_193000_db_home.zip`) or, for another name (an
  edelivery `V982063-01.zip`, a renamed file), from inside the zip; Grid or database also from inside the zip.
  Only the release of the primary is used, so other releases in the same folder do no harm.
- The files must belong to root, oracle or grid, and only their owner may change them (for example
  `chmod 644`); others are listed as not used, with the reason.
- 12.1 comes as two zips: keep their names ending in `_1of2.zip` and `_2of2.zip`.
- A Release Update and OPatch are not searched for: when the primary is patched, step 3.1 says so; set the
  value "Release Update" on the summary screen (RU_DIR, the unzipped RU, and OPATCH_ZIP, `p6880880_*.zip`).
The summary screen (step 1.4) shows the zips found, on the line "Installer zips".

### `--settings`
Shows the summary screen and the values of the setup (a number changes one, `e` opens the settings file in
`$EDITOR`), then stops.

### `--status`
First a short Data Guard block: role and open mode, protection mode, redo apply (MRP), transport and apply lag,
and the last applied log per thread. It is read now, read-only, when the standby instance runs on this server;
otherwise the values recorded by the last `--health` or phase 10 are shown, with their time. Then when
`--health` and phase 10 last ran (with the result and the log), the result of every phase, every step with its
result, when it ran and, for a step that is not done, why (ok, done, waiting, failed, skipped), and the runs
behind these results with the path of each run log. It never connects to the primary, so it also works when
the primary is down.

### `--plain`
Plain scrolling output, as in earlier versions: every message stays on the screen in order. Used by itself
when the terminal is smaller than 80 x 24 or is not a terminal.

### `--verbose`
Shows what the checks read. Every step is shown in full (by default a step that is already correct is one
line), and under it each read-only query or command it ran, with its answer:
```
  Step 9.4  Redo apply (MRP)
      · STANDBY sqlplus: select count(*) from v$managed_standby where process like 'MRP%';  ->  1
    ✔ Redo apply (MRP) is running
```
Commands that change something are always shown (under "Will run" before `[y]`, and "Running as ..." while
they run). At the end, the full table of every step. With `--health --verbose`, the queries of each check
are listed under its line (the first line, the status, stays the same for monitoring). The run log always
has every query with its answer. `DG_VERBOSE=1` in the environment does the same.

### `--show-changes [step]`
Lists every change the script made on this server (files written, settings, users, disks, services,
database changes), each with how it is undone. With a step number, only that step: `--show-changes 6.1`.

### `--undo <step>`
Undoes the changes of one step, newest first, and asks before each one. A file is restored only when it
is still what the script wrote; something that may hold data is never removed. Changes on the primary are
shown for you to undo there.

### `--help-step <step>`
How to do a step by hand: where, as which user, the commands, the expected result. `--help-step all`
prints every step; `--help-step health` explains `--health`. The commands use your saved names. They are
printed at column 0 between two rules, so they can be copied as they are; explanations in that block are
`#` lines (`--` inside sqlplus or rman).

### `--health`
The checks of phase 10 for cron or a monitoring agent: no questions, no changes, no terminal needed.
Checks, in this order: the standby instance (down is CRITICAL at once), 10.1 transport and apply lag
(and whether data from the primary still arrives), 10.2 archive gap (and whether missing logs are still on
the primary), 10.3 last log on both sides, 10.4 redo apply and real-time apply, 10.5 NOLOGGING blocks,
10.6 patch level of both database homes, 10.8 archived logs (space and the nightly clean-up). A problem in
10.1-10.4 is checked once more after 60 seconds.

The **first line** is the status in the form monitoring systems read (Nagios), with the lag as perfdata:

```
OK - standby PRODDB_STBY, redo apply running; lag: transport 0 s, apply 1 s (limit 300 s); protection MAXIMUM PERFORMANCE | transport_lag=0s;;300;0 apply_lag=1s;;300;0
```

Then the title, one line per check, a `Data Guard:` line (role, open mode, protection mode, last applied log),
notes, and `Result: <state> (exit N). Details: <log>`. Details go to `health_<time>.log` (14 days, at most
500 files). Exit code: `0` OK, `1` WARNING, `2` CRITICAL, `3` UNKNOWN (could not check, another run active,
after a switchover, or a wrong option).

The checks on the primary need an ssh key of root (step 9.9, see below). Without a key the primary is
**not checked** and that does not make the result UNKNOWN: 10.3 and 10.5 are done on the standby side only
(the last log received against the last applied; the standby's list of NOLOGGING blocks), 10.6 is
`SKIPPED`, and a note line says `primary not checked: no ssh key for root ...`. Other ssh errors (no
answer, a changed host key) still give UNKNOWN for those checks.

### `--roll-forward`
For a standby that cannot catch up (archived logs it needs were deleted on the primary) or after
NOLOGGING work: runs `RECOVER STANDBY DATABASE FROM SERVICE` (18c and later) instead of a new copy.
Asks for the sys password and the word `ROLLFORWARD`; never runs with `--yes` or `--check`.
Checks first, and stops on any doubt: standby mounted, no RMAN session or long job running, broker off,
static listener entry, every TDE wallet of an encrypted standby (each container) auto-login and open, both
RMAN logins, and that RMAN can find the standby's datafiles again (same names, a `db_file_name_convert` that
gives every standby name, or Oracle-managed files). Afterwards it sets the standby redo logs and RMAN
settings again and starts redo apply. If the terminal closes meanwhile, the next `--roll-forward` checks it
and, after `ROLLFORWARD` is typed again, finishes it without running RMAN again. On 12.1/12.2 it shows the
manual way.

### Settings that change behaviour
- `HEALTH_LAG_MAX`: lag in seconds that `--health` accepts (empty = 300, at least 30).
- `DUP_SECTION_SIZE`: section size of the RMAN copy, for example `32G`. Empty = automatic (32G when a
  datafile is 64 GB or more and there is more than one channel; needs COMPATIBLE 12.0+), `0` = never.
- `AUX_CHANNELS`, `PRIMARY_CHANNELS`: RMAN channels on this server and on the primary (1-64; asked before
  the copy, with the CPUs of both servers and a suggestion).
- `DATA_DEST`: where the database files of the standby go: `+DG` (a disk group, Oracle-managed names), `same`
  (the paths of the primary), or a folder. Empty = automatic: the data disk group when this server has ASM.
- `FRA_DEST`, `FRA_SIZE`: the recovery area of the standby and its size (empty = estimated from the redo of
  the primary: the archived logs of the copy time and one day, plus 30 %; at least 10 GB).
- `ARCH_CLEANUP`: how applied archived logs are deleted here: `timer` (systemd, default), `crontab` (a line
  in the crontab of oracle), `oracle` (only the recovery area itself), `none`. `ARCH_CLEANUP_TIME` (HH:MM,
  04:30), `ARCH_CLEANUP_DAYS` (0-30, 1).
- `PRIMARY_RUN`: `yes` lets primary steps offer to run their listed statements over ssh (default `no`).

### Exit codes
`0` every step OK; `1` stopped by you, or some steps are not OK or skipped (normal for `--check` on a new
server); `2` wrong option or unknown step; `4` a step failed. With `--health`: `0` OK, `1` WARNING,
`2` CRITICAL, `3` UNKNOWN.

## Daily check from cron

The daily check is `--health` (from cron or a monitoring agent). By hand, with the screen and questions:
`./dg_standby_setup.sh --only 10`.

```bash
# root's crontab on the standby: the alert gets the output (its first line is the status)
17 6 * * *  out=$(/root/dg_standby_setup.sh --health) || /usr/local/bin/my-alert "$out"
```

Do not send the output to `/dev/null`: the alert would then not say what is wrong. (In a crontab line a `%`
must be written `\%`; the line above has none.) A monitoring agent (NRPE and the like) should allow 300
seconds, since a problem is looked at twice, 60 seconds apart.

### The ssh key for the primary checks (step 9.9)

Cron cannot type a password, so `--health` logs in to the primary with a key of root. Step 9.9 makes it
(`/root/.ssh/dg_health_<standby unique>`, ed25519, no passphrase, mode 600) and shows the exact line for the
primary. It is optional: skipped, `--health` checks the standby only (see above). To do it later:
`./dg_standby_setup.sh --only 9.9`. By hand:

```bash
# 1) on the standby, as root
ssh-keygen -q -t ed25519 -N '' -C 'dg_standby_setup health stby01' -f /root/.ssh/dg_health_proddb_stby
cat /root/.ssh/dg_health_proddb_stby.pub
```

```bash
# 2) on the primary, as the ssh user (oracle): one line, the standby's address, then the whole .pub line
mkdir -p ~/.ssh
chmod 700 ~/.ssh
echo 'from="192.0.2.20",no-port-forwarding,no-X11-forwarding,no-agent-forwarding,no-pty ssh-ed25519 AAAA... dg_standby_setup health stby01' >> ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys
```

```bash
# 3) test on the standby, as root: prints OK without a password question
ssh -i /root/.ssh/dg_health_proddb_stby -o BatchMode=yes \
  -o UserKnownHostsFile=/var/lib/dg_standby_setup/primary_known_hosts oracle@192.0.2.10 echo OK
```

`from=` lets the key in only from the standby's address; `no-pty` and the `no-*-forwarding` options give it
no terminal and no tunnels. `--health` uses this key when the file exists (`IdentityFile`, `BatchMode=yes`,
and the same host key check as the setup). To take it back: remove the line on the primary, and
`./dg_standby_setup.sh --undo 9.9` on the standby.

HEALTH_LAG_MAX in the settings sets the accepted lag (300 seconds by default, at least 30).

## When the standby cannot catch up

If archived logs the standby needs were deleted on the primary, step 10.2 says so and names two ways: restore
them on the primary from its backup, or (18c and later) `./dg_standby_setup.sh --roll-forward`. That runs
`RECOVER STANDBY DATABASE FROM SERVICE`: the standby fetches only what it misses, as incremental backups.
Before it starts, the script checks that the standby is mounted, that RMAN can find the standby's files again
afterwards, that no other RMAN session or long job runs, that the broker is off, that the listener has a
static entry for the standby, that every wallet of an encrypted standby opens by itself, and that both RMAN
logins work. Afterwards it sets the standby's own standby redo logs and RMAN settings again and starts redo apply.
Try it once on a test standby before you need it.

## Safety design

- **Primary is read-only.** Only whitelisted probes and `SELECT` statements go to the primary (with
  `PRIMARY_RUN=yes` also the listed Data Guard statements, each step after you answer `y`).
  The SQL guard checks the script's own statements. A `glogin.sql` (or `login.sql`) on the primary runs at
  every sqlplus login and belongs to the DBA there.
- **Oracle Net encryption is not checked.** The RMAN copy and the redo go over Oracle Net as your site set it
  up. On a network you do not trust, configure native network encryption (`SQLNET.ENCRYPTION_SERVER` /
  `SQLNET.ENCRYPTION_CLIENT` in `sqlnet.ora` on both servers) or TCPS before the copy.
- **No data is erased without proof.** A disk is used only after it is shown to be empty and not shared with
  the primary. A check that times out counts as "no". The clean-up of a failed copy first proves that this
  is the standby (host name, address, the running instance's `db_unique_name` and role) and asks for the
  word CLEAN; only the standby's own files go, never the pfile or the password file.
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

In the log folder, `run_<id>.log` is the whole run, `actions_<id>.txt` every command shown to you, and
`commands_<step>_<id>.txt` the commands of one step as a runnable script (`bash commands_8.2_<id>.txt`, or
read it first with `less`).

## Repository layout

```
dg_standby_setup.sh   the ready-to-use script (built from src/)
src/                  source, split by phase; build.sh joins them in a fixed order
build.sh              rebuilds dg_standby_setup.sh from src/
CHANGELOG.md          what changed in each version
.github/workflows/    CI on every push (ci.yml) and the release of each new version (release.yml)
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

The suite can also run in parts: `./run_scenarios.sh --list-parts` shows them, `--part 3` runs one, and
`--sections A,Q` runs only the named sections. GitHub Actions (`.github/workflows/ci.yml`) runs shellcheck,
the build check (`bash -n`, and the committed script must match the build of `src/`), every part as its own job, and
sections A and Q on Oracle Linux 7 (bash 4.2) in a container.

The mocks are not real Oracle. Before using the script in production, run `--check` on the real servers
and read what it reports.

## Disclaimer

Provided as-is, without warranty. Test it in a non-production environment first, and keep a verified
backup of the primary.
