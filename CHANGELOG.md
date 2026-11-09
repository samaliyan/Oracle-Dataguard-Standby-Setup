# Changelog

The script file of each version is attached to its release on GitHub as `dg_standby_setup-<version>.sh`
(with a `.sha256` checksum).

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
