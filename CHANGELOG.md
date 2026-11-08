# Changelog

The script file of each version is attached to its release on GitHub as `dg_standby_setup-<version>.sh`
(with a `.sha256` checksum).

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
