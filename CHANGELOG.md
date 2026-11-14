# Changelog

The script file of each version is attached to its release on GitHub as `dg_standby_setup-<version>.sh`
(with a `.sha256` checksum).

## 5.34

- Step 2.13 with the screen layout: the empty disks for a disk group are a list to mark. `↑` `↓` move,
  `Space` marks, `Enter` takes the marked disks; the size marked is shown against the size needed, and an
  answer that is not taken (too small, already chosen) is said on the page. Typed numbers work as before.
  Nothing else changed: the commands are shown next and every disk is confirmed by typing its name.
- `--show-changes` with the screen layout and no step named: a list of the steps that have changes, with
  their number of changes and how they are undone. `Enter` shows the changes of the marked step with their
  undo, `u` goes on to the undo of that step (the run of `--undo STEP`: every change is asked), `a` shows the
  whole report, `q` leaves. Menu item 12 uses the same list. `--show-changes STEP`, `--plain` and output to a
  pipe or a file give the report as text, as before.
- Tests: section 5.34 (a new part 12 of the suite).

## 5.33

- The start menu is a page with the screen layout: `↑` `↓` move the mark (it starts on the item Enter takes),
  `Enter` takes the marked item, a typed number works as before. On a terminal with fewer than 30 rows the
  empty lines between the groups are left out, so all 14 items fit in 24 rows. What an item prints (status,
  changes, the manual way of a step) stays on the screen until Enter; the chosen item is named on the screen.
- Summary page on a small terminal: the page moves with the mark, so the values below the page can be
  reached with the arrow keys too (before: only by their number). "… N lines above" says that it moved.
- The line above a question on these pages is never longer than the terminal is wide (a wrapped line moved
  the page by one row on 80 columns).
- Without the screen layout (`--plain`, a small or plain terminal) the menu is printed and asked as before.
- Tests: section 5.33.

## 5.32

The summary screen (step 1.4, `--settings`) is used with the keyboard like a form.

- `↑` `↓` move a mark over the values of the run; `Enter` changes the marked value; `Esc` takes the mark away
  (with no value marked, `Enter` starts, as before). The line above the question says what the keys do now.
  After a change the mark is gone, and the arrow keys go on from the value that was changed.
- Values with a fixed set of answers open a choice page that lists the answers with their meaning: where the
  database files go, the recovery area, the ASM disk method, the clean-up of archived logs. `↑` `↓` and
  `Enter` take one, `Esc` changes nothing, and a typed value works too (a folder is typed).
- Nothing else changed: a typed number and typed values work as before, also typed ahead; `--plain` and a
  screen too small for the layout ask the same questions as before.
- Tests: section 5.32 (the test driver sends arrow keys and takes pictures of the pages).

## 5.31

The four small open points of the 5.30 review.

- Step 3.9: every change is in the journal (`--show-changes`, `--undo`): the edit of listener.ora (undone from
  its backup) and the stop of a listener of another home that held the port (how to start it again). The copy of
  /etc/hosts that step 2.6 made in the same run is no longer replaced.
- Step 2.4: the limits of the user `oracle` are checked like those of every other owner (before, the script
  trusted the preinstall package without looking). A missing or too low limit is added; with HugePages on the
  primary, memlock is checked against its SGA for `oracle` too.
- PATH: the commands run as root use only folders of PATH that belong to root and that nobody else can write
  to, plus the system folders. After `su` without `-`, a folder of the user who became root is left out (and
  named once at the start).
- Step 3.1 prints the SHA-256 of each installer file (also in the run log), to compare with Oracle's download
  page or with the gold image on the primary.
- Tests: section 5.31.

## 5.30

A strict review by five independent reviewers (Oracle, installation, the engine, security, documents and tests).
Every finding was checked in the code before it was changed; the ones below were real.

Would have failed on a real server:
- Listener of the Grid home: the static entry now has `(ENVS = "TNS_ADMIN=<database home>/network/admin")`.
  Without it the server processes of the copy look for the primary alias in the Grid home and RMAN ends with
  ORA-17629 / ORA-12154. Step 5.1 finds an entry without it and replaces it.
- Database installer (3.6): the OS groups of the response file are only groups the database owner is a member
  of (before: any group that exists, such as `oper` or `backupdba` made by the preinstall package, and the
  installer stopped with INS-35341).
- Standby redo logs (4.2, 9.3): with `db_create_file_dest` and a recovery area and no
  `db_create_online_log_dest_n` (the usual ASM layout) Oracle made a second member in the recovery area. The
  statements now name the place there too: one member per standby log.
- 23ai: the instance is also found by its new process name `db_pmon_<SID>`.
- A `startup mount` that only printed ORA-32004 (a deprecated parameter in the spfile) counted as failed.
- 10.1: the lag diagnosis found no destination on 12.2 and newer (`target` is REMOTE there).

Safer:
- Nightly clean-up of archived logs: only while the database is a physical standby. After a switchover it
  deletes nothing (before, it went on deleting the logs of the new primary).
- A full disk no longer replaces the settings file with an empty one (the write is checked; the old file stays).
  The files of the progress and of the primary commands are kept the same way.
- Shared-storage test (2.14): the test file is made with noclobber, so root never writes through a link that a
  member of the Oracle groups put there.
- The files of the screen layout are in a folder of their own (mode 700) instead of readable files in /tmp.
- The input of the copy (it holds the SYS password) is no longer passed through here-strings, which older bash
  keeps in a temporary file.
- ssh to the primary: no agent or port forwarding, whatever root's ssh configuration says.
- A long job: Ctrl+C right after its start asks as later on; a job whose result was read is not taken for running
  by the next run when programs it started are still there; the job no longer holds the output of the script
  open (`| tee` ends with the script).
- Output sent to a file (`> file`) is refused with a hint (the questions would not be seen); `| tee` works.
- No colour codes with TERM=dumb. `--undo` renames the inventory and wallet files moved aside back
  (`.old_<run>`), as `--show-changes` says. The free-space check of 2.14 counts the recovery area where it goes
  on the standby. chrony is not installed next to a running ntpd. After `--roll-forward` the "Next" line names
  `--roll-forward` again.

Project:
- Release: made only after the CI of that commit has passed, only from main, and only when CHANGELOG.md has
  the section of the version.
- Tests: they refuse to start on a machine that looks like a real Oracle server (they delete the users oracle
  and grid); section 5.30 tests the fixes. `build.sh` takes every `src/NN_*.sh` by itself.
- README: which release runs on which Oracle Linux, the real default of `FRA_SIZE`, the `[a]` answer, the
  checksum, what the tests destroy, and a "Known limits" section (21c / 23ai read-only homes, the `--health`
  key, the boot unit after a switchover, installer checksums). README.fa: the current menu.

## 5.29

- The installer zips are also searched for in the folder of the script itself (first, three levels deep), so
  the script and the zips can be put together in any folder. The messages for missing zips name that folder.
- Summary (step 1.4): an installer zip saved in the settings by an earlier run that is gone or no longer
  usable is named under "Problems found now" and marked "(missing)" on its value line (before, only step 3.1
  said so).
- README: where to put the installer files, how the release is found (file name or the inside of the zip),
  the owner and mode they need, 12.1 pairs, and the Release Update.

## 5.28

- `--verbose` shows what the checks read: every step in full, and under it each read-only query or command it
  ran with its answer (`· STANDBY sqlplus: select count(*) from v$archive_gap;  ->  0`), also the probes on the
  primary. Commands that change something are shown as before, with or without it.
- `--health --verbose`: the queries of each check under its line. Without `--verbose` the output is the same as
  before (the first line is still the status for monitoring).
- `--health`: the checks no longer read the instance state, the role and the datafile headers again before each
  check (they were read once at the start); its log is shorter.

## 5.27

The five open points of the 5.26 review.

- Standby redo logs have one member each (Oracle MAA: a second member only slows down the writing of the redo
  that arrives). With two or more OMF log destinations (the multiplexed logs of 5.26) the statements name the
  first one, for example `alter database add standby logfile thread 1 ('+DATA') size 200M;`. The same rule is
  used for the standby logs of the primary (step 4.2).
- Space check before the copy (8.1): the second member of every online log, which goes to the recovery area's
  place when the logs are multiplexed, is counted there ("second log members"). The standby logs are counted
  once (one member).
- A second run is short: a step that is already correct is one line (`✔ 2.1  Groups ...  All 10 groups
  exist ...`). A step that asks, does something or finds a problem shows its full text as before.
  `--verbose` shows every step in full.
- `--show-changes`: an overview first (changes on this server, how many `--undo` takes back by itself and how
  many are by hand, the commands you ran on the primary, the runs), one line per step, then every change with
  its undo, by step number; a note shared by a group (for example "only if no file and no user uses it") is
  printed once under it.
- Run log: a SQL query that succeeds with a one-line answer is one line (`query  ->  answer`); in the other
  blocks the query is written once and the internal output marker is left out. Errors and longer answers keep
  their block. A full run's log is about half as long.
- Tests: the multiplexed-log path is tested (the mock answers the members query and the online log size).

## 5.26

Before the first real use: four independent reviews of real runs (the work flow, the screen layout, the logs and
errors, and a senior DBA's view), then these changes.

Safer to copy and to read:
- Commands for you are copy-safe: the lines in the boxes start at column 0 (a heredoc's `EOF`, tnsnames and
  listener entries work when pasted), shell blocks use `#` comments, and `commands_<step>_*.txt` and the actions
  file are scripts you can run as they are. Help texts follow the same rule.
- Screen layout: command lines are never broken by the script (the terminal wraps them, so a copy is one line);
  a step that does not fit keeps its title, status, the start of the plan, the "Will run" heading with the
  first and last commands, warnings and the question; the result of the previous step stays while there is
  room; the log path is in the map; a compact map on small screens.
- A failed step ends the run: "Stopped: step X failed (error)", exit code 4 (1 = stopped by you), no extra
  question. The end summary is one line per finished phase (`--verbose` for every step), with a
  "Data Guard now" block after a full run. The run log has an END line, the time of each step, the values of
  the run; job files have a header and a footer, and a retry does not overwrite the first one.

Errors you can act on:
- Installer prerequisites: the failed checks (with their PRVF/PRVG ids) are read from the installer's own log
  and shown before the question: fix and run again, or run again ignoring them (type IGNORE). root.sh errors
  are taken from its log.
- RMAN copy: progress while it runs (datafiles, GB, time left); on failure the whole error stack, the likely
  cause, the standby alert log, and what is left on this server.

Data Guard (agreed with the owner):
- Two control files on the standby, and redo log members as on the primary (multiplexed).
- The standby's recovery area is as large as the primary's: 8.1 stops when the space is not there; a smaller
  size only when set on purpose, with a warning.
- New step 9.9: an ssh key so that `--health` can check the primary too (a restricted authorized_keys line).
  Without it, `--health` checks the standby side and marks the primary checks SKIPPED (not UNKNOWN).
- One visit to the primary: the commands of 2.7 (/etc/hosts) and the 6.1 preparation join the phase-4 block,
  per OS user; the restart of 4.1 is a separate DOWNTIME box (srvctl under Oracle Restart).

Smaller:
- `--health`: the first line is the status (Nagios form, with lag perfdata); protection mode shown.
  `--status` starts with the Data Guard state.
- Summary (1.4): problems first, a names table (primary | standby), the installer files found, Release Update
  and channels as values (8.2 does not ask the channels again). 3.1 records the installer files without a
  question. `--check` plans the same ASMLib group as the real run.
- Primary changes are journaled with their old and new value. The run log shows read-only probes as one line.

## 5.25

What is shown is what runs, in every step. The notes of 5.23 said that every automatic step shows its exact
commands under "Will run" before `[y]`; that was true for phases 3, 7.2 (clean-up), 9 and 10 only. Phases 2, 5
and 6, parts of 7 and 8, and the installer jobs showed a description instead. Now every step that changes
something on this server lists the exact command lines with their real values under "Will run" (passwords
*****) before `[y]`, runs exactly that list, shows each command again when it runs ("Running as <user>: ..."),
and logs it.

- Phase 2: groups, users, packages (the proxy settings of the environment are passed on), limits, folders,
  `/etc/hosts`, firewall, time sync, `.bash_profile`, ASM method, ASM disks (shown once the disks are chosen,
  before the typed confirmation), `/dev/shm`.
- Phase 3: the unzip, installer and root-script jobs show their exact command lines before `[y]`, and a job
  that was not shown is not started; the response file is named with its path, and the values the script
  sets in it are listed in a file under the log folder (passwords *****). OPatch, inventory fixes, disk
  groups, `roohctl`, the listener port.
- Phases 5 and 6: `listener.ora`, `tnsnames.ora`, `sqlnet.ora` (the block added, or the whole new file),
  `lsnrctl start` / `reload`, the password file and wallet copies (the exact `scp`, the md5 check, the
  install), `orapki` (the keystore password is typed when it runs and never shown). A file changed after the
  check is not written.
- Phases 7 and 8: instance folders, the pfile and `startup nomount`, `/etc/oratab`, `setasmgidwrap`, the RMAN
  duplicate (its whole input). The 7.2 clean-up shows its commands before you type CLEAN.
- Phases 9 and 10: `srvctl add` / `modify` / `remove` (and the command that would put the old registration
  back), standby redo logs, redo apply, the boot unit files and `systemctl` commands, the roll forward and the
  clean-up after it.
- Each step works its list out again before it acts; if it differs from what was shown (something changed in
  between), nothing is run and you are asked to check again.

## 5.24

From an external review of 5.23 (four reports). Every finding was checked against the code; the ones that held
are fixed here. No finding was a data-loss bug; several made a check say OK when it could not know.

Fixes:
- 10.8 / --health: no longer OK when the free space of the recovery-area disk group cannot be read, when no
  archive clean-up was chosen (waits), or when ARCH_CLEANUP=oracle and logs are written outside the recovery
  area (problem). A recovery area in a folder also gets a real `df` check; every local archive destination is
  checked; ASM destinations warn below 20% free; the RMAN deletion policy is read again.
- The nightly clean-up script refuses a "BACKED UP n TIMES" deletion policy (RMAN deleted nothing and the job
  still reported success) and prints the policy it found.
- 8.1 (pre-checks before the copy, also with `--from 8.1`): the release of this server's database software is
  compared with the primary again (a patch-only difference is a warning: standby-first patching is allowed);
  an unreadable spfile setting of the primary stops; FORCE LOGGING off stops. 4.1, 8.1 and 10.5 accept
  STANDBY NOLOGGING.
- 6.3 / TDE: every wallet folder is checked before the copy; LOCAL auto-login is judged per folder; an existing
  local `cwallet.sso` is tested (age, `orapki wallet display`) and moved aside when it cannot open here; the old
  3-column wallet query is used only after ORA-00904. 6.1 / 6.3: failed reads are "cannot check", never
  "empty".
- 7.2: leftovers that cannot be cleaned automatically are not reported as OK; ASM folders or primary file
  names that cannot be read are listed as "not checked" and only the manual way is offered; `[y]` journals each
  deletion after it worked; the `[m]` file checks the database (db_unique_name, standby role) before it
  deletes; `rm -rf --one-file-system`; a failed mount does not use up the one try; a host name with domain is
  accepted.
- 9.1: the rollback `srvctl add` has a time limit; unreadable ASM only blocks when a disk group is involved;
  attributes not carried over by a re-registration are listed. 9.7: no 5-minute wait when the boot unit has
  already ended; `srvctl status` in the message. 9.8: a cron log with the wrong owner is chowned, not emptied.
- 4.4 also finds an existing destination in `log_archive_dest_1`.
- Channel counts: `abc`, `08` or `1.5` no longer end the script (at the question, in the settings file and on
  the summary screen).
- The summary names the right value numbers and shows `[h]`; Ctrl-C there restores the terminal; a lone `l` or
  `d` is not taken as a host or user name; menu 7 and `--only` say that 10.7 runs only with `--roll-forward`.
- `--check` no longer sends 64 MiB from the primary to measure the network.
- The probe marker is random per run and must be on a line of its own; a failed host-key save stops;
  `ssh -O check` and `mktemp` failures are reported as such; local ssh/sqlplus time limits kill after 30 s.
- `DG_*` path overrides must be plain absolute paths; the folder for command files must be root-only.
- 3.9: the listener.ora HOST fix escapes dots the same way on bash 4.2; a resource in state UNKNOWN is not
  started blindly. The manual `find ... -delete` uses `-xdev`. Media plans list every missing file.
- `--health`: a second look also for 10.8 and UNKNOWN results; SQL time limit 60 s (unless `DG_SQL_TIMEOUT`);
  boot-unit errors shown as a note.
- The startup line, `DESIGN.md` and both READMEs are accurate about `PRIMARY_RUN=yes`; the READMEs say what
  the SQL guard covers and that Oracle Net encryption is not checked by the script.

Not changed, by design (see the review notes): the listener port is opened per firewall zone (clients must
reach it after a switchover); root runs Oracle's own root scripts; `$EDITOR`; the `-nt` guard of the `[m]`
clean-up file.

Tests: GitHub Actions CI (shellcheck, build check, the suite in 11 parallel parts, Oracle Linux 7 with bash
4.2); 20 new checks for these fixes; mocks independent of the test machine (RAM, `/dev/shm`, IP address).

## 5.23

From a real run on a standby (Oracle Restart 19c on OL7, a primary with files in folders and in ASM). The goal:
no manual work where the script is allowed to do it.

Fixes:
- 3.4 / 3.9: `ora.*` resources are started with `srvctl` (never `crsctl start res`, CRS-4995). Only ASM, the
  listener and the disk groups in use are checked; `ora.diskmon` and `ora.ons` are OFFLINE by design.
- 3.9: a listener in INTERMEDIATE ("Not All Endpoints Registered") is not started blindly: the cause is found and
  fixed first (the host name missing from `/etc/hosts`, a port held by another listener, a wrong HOST in
  `listener.ora`), then the listener is stopped and started.
- 2.6 / 2.7: a host name that only answers with an IPv6 link-local address (`fe80::`) counts as missing, on both
  servers.
- 8.2: the error summary of a failed copy shows the first real error (not the frame `RMAN-00571`).
  ORA-19809 / ORA-19804 are recognised as "the recovery area on this server is full".
- 9.2: an instance started by RMAN that does not stop (ORA-01012) is recognised as hung; `shutdown abort`
  (with `sqlplus -prelim`) is offered, then the standby is started under Oracle Restart. `shutdown immediate`
  has a time limit.
- 1.3: the service of the primary is also found with a domain, as the database name, in `service_names` or as
  a root service, before anything is assumed.

New:
- Every automatic step shows the exact commands under "Will run" before `[y]`, and each command is shown again
  when it runs ("Running as grid: ..."); the log has the full command lines.
- Commands for you are commands with real values; long ones go into a short script file under `/root/dg`.
- Where the standby files go: by default everything into the data disk group when this server has ASM
  (`set newname for database`, control files and logs there too). Settings `DATA_DEST`, `FRA_DEST`, `FRA_SIZE`.
  The recovery area size comes from the redo of the primary, not from its size. 8.1 checks the space of data,
  standby logs and recovery area together, before the copy.
- RMAN channels on the primary and on this server are asked before the copy; the network speed is measured
  for the expected time.
- After a failed copy, 7.2 offers `[y] Clean up for me` (with proof that this is the standby, and the word
  CLEAN), `[m]` a script file to run yourself; a bigger recovery area after ORA-19809; the copy then runs again.
- A standby copied outside the script is accepted.
- Start: a grouped menu with the switch of each item, and one summary screen after phase 1: what was found,
  where each kind of file goes, the plan, the problems found now, and the values of this run (a number changes
  one). `--check` prints it.
- `[a] Yes to all` in every step question (risky actions are still asked).
- Optional `PRIMARY_RUN=yes`: a primary step may run its listed Data Guard statements over ssh after you answer
  `y` (never a restart, a stop, a deletion or a file).
- Archived logs: `ARCH_CLEANUP` = timer (default), crontab (a line in the crontab of oracle), oracle (only the
  recovery area) or none, with `ARCH_CLEANUP_TIME` and `ARCH_CLEANUP_DAYS`. New check 10.8 (also `--health`):
  recovery area use with its reclaimable part, and the last run of the clean-up.
- The screen: a step text longer than the screen is folded and cut with "N more lines: d shows all". The cut
  part never holds where the commands run ("Run on the PRIMARY (host), as grid"): that heading stays above the
  commands that are shown. `d` shows the whole text of the step, uncut.
- A check step that fails shows its fix once (not again under "Fix" when the status already says it).

Not in this version: the copy by backup and restore (method b); it comes later.

## 5.22

A new screen, and a fix in step 3.2:
- The top of the screen is a fixed map: every phase with its steps done out of all, the current one, and
  the totals (done, need attention, to go). Below it only the current step, with the steps of its phase
  done before it as one line each (and their warnings). A retry starts on a clean area ("attempt 2").
- At any question: `l` lists every step (a step number opens its details), `d` shows the details of the
  current step, `h` its help. They open on a separate screen; closing it returns to the step.
- Installers, root scripts and the RMAN copy show one live line (what runs, how long, keys `l` and `d`)
  instead of their output, which stays in its file. Long lines are wrapped at word borders.
- `--status` lists every step with its result, time and reason. `--plain` keeps the plain output, which is
  also used in a terminal smaller than 80 x 24, without a terminal, and for `--health`.
- 3.2: a Grid installer that finished, before its root scripts ran, was taken for a half-installed home
  (real 19c homes get `bin/crsctl` from root.sh). It is now recognised; 3.3 then runs the root scripts.
- "Finished with warnings" of an installer is shown on every attempt, not only the first.

## 5.21

Fixes from the independent review of 5.20:
- `--roll-forward` checks more before anything is changed: every TDE wallet of the standby (each container,
  not only the root) must be auto-login and open; a `db_file_name_convert` counts only when it really turns
  every primary datafile name into the standby's; the release is read from the standby itself.
- `--roll-forward`: a wrong sys password can be typed again in the same run; finishing a roll forward that
  ended unwatched asks for ROLLFORWARD again and shows the flashback note; when the clean-up afterwards does
  not finish, the exact commands still to do are shown (also when redo apply did not start).
- 10.2: the restore commands name only the logs that are really gone from the primary, and logs found missing
  are no longer lost from the report when a later read fails.
- 10.5 and `--health` on a 12.1 standby: force logging is checked and reported OK (no UNKNOWN every run).
- 10.6: a patch folder that cannot be listed here is "cannot check", not a list of differences.
- 10.1: "no data from the primary" is reported whatever the old lag values say.
- `--health`: the reason a run stopped is no longer labelled with a state that can differ from the result.
- Firewall note: no note when port 1521 is explicitly accepted; a rule that drops the port is shown first.
- All ASM password file copy commands for the primary keep the file private (`umask 077`).
- srvctl "not registered" is recognised only by its own codes or a message naming the database.
- Programs Oracle needs root to run are checked with every folder above them, not only their own.
- Undo: restores keep the original owner; a read-only file and a folder its owner cannot write are handled.
- Smaller fixes: memory message in the copy checks, folder as target of a file write, installer temp folder
  warning, folder group on creation, 5-digit patch ids, Ctrl+D message, `--only 10.7` message, 9.1 shows a
  registered disk group ASM does not see as attention.

## 5.20

New:
- `--health`: unattended health check for cron or a monitoring agent. No questions, no changes, one line per
  check, exit code 0 OK / 1 WARNING / 2 CRITICAL / 3 UNKNOWN. Checks the instance first; a problem in lag,
  gap, last log or apply is checked once more after 60 seconds. Details in `health_<time>.log` (14 days).
- `--roll-forward` (step 10.7, 18c and later): brings a standby that cannot catch up up to date from the
  primary with `RECOVER STANDBY DATABASE FROM SERVICE`, instead of a new copy. Many checks first; afterwards the
  standby redo logs, the recovery area catalog and the deletion policy are set again and redo apply restarts.
- Step 10.5: NOLOGGING blocks on the standby (`v$nonlogged_block`), and force logging on the primary.
- Step 10.6: the patches of the database homes on both servers are compared.
- 10.1: "no data from the primary for N seconds" is reported even when the lag shows 0 (`datum_time`), and
  a high lag shows the error of the primary's destination for this standby.
- Known Data Guard error codes are explained with their usual cause and the step that fixes them.
- 10.2 says when the logs of a gap are no longer on the primary, with the restore commands.
- RMAN copy: `SECTION SIZE 32G` when a datafile is 64 GB or more (setting `DUP_SECTION_SIZE`).
- The switchover readiness command (`alter database switchover to ... verify`) is shown when all is well.
- Settings `HEALTH_LAG_MAX` and `DUP_SECTION_SIZE`.

## 5.19

Final independent audit (six reviewers). Among the fixes: a software folder is emptied with `find -delete`
(no path race), Oracle programs run as root are checked first, files in oracle's folders are written by
oracle itself, the SYS password no longer appears in the process list for a moment, srvctl and ssh failures
are "cannot check" instead of a wrong state, a finished RMAN copy can no longer look unfinished.

## 5.18

Root steps for the audit folder only under folders that no one but root can change; folders below a
non-root folder are made by their owner; clearer firewall note; usable-space note in 4.6.
