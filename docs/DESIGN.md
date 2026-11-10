# dg_standby_setup.sh 5.20 - design

Runs as root on the future STANDBY. Builds a physical standby of one primary database.
Never changes the primary on its own: primary work is printed, then re-checked read-only.
Only with PRIMARY_RUN=yes may a primary step run listed Data Guard statements over ssh, after you answer y.

## Supported
- Oracle Database 12.1, 12.2, 18, 19, 21, 23ai (single instance primary; RAC primary -> stop).
- Oracle Linux 7, 8, 9 on the standby (yum on 7, dnf on 8/9). bash 4.2+ (set -u only on 4.4+).
- Primary storage: ASM, filesystem, or mixed. Each storage location of the primary
  (+DG or directory) is created on the standby with the same name/path.
- Grid: separate owner (grid) or the same owner as the database (oracle).
  Grid (Oracle Restart) is installed on the standby only when the primary uses ASM.
- Primary environment (.bash_profile) is never relied on.

## Discovery (read-only, over one ssh connection, fixed probe list)
Before the connection: the host key of the primary must already be known (root's known_hosts, or
/var/lib/dg_standby_setup/primary_known_hosts). A new key is read with ssh-keyscan, its fingerprints are shown
with the command that prints them on the primary, and it is saved only after the admin answers y. The ssh
master then runs with StrictHostKeyChecking=yes: ssh never asks to accept a key, and a changed key stops it.

1. host name
2. processes: `ps -eo pid,user,args` -> ora_pmon_<SID>, asm_pmon_+ASM*, tnslsnr <home>/bin/tnslsnr <NAME>
3. DB home: /etc/oratab line for the SID; else `readlink /proc/<pmon pid>/exe`; else ask the user.
4. TNS_ADMIN of the running DB: `/proc/<pid>/environ` (only readable as the DB owner); else orabasehome (18+); else $OH/network/admin
5. Grid home: oratab +ASM line, /etc/oracle/olr.loc crs_home, readlink of asm pmon exe
6. owners (stat of bin/oracle), ids, Oracle bases (orabase)
7. SQL (sqlplus / as sysdba, SELECT only): version (v$instance.version; version_full for 18+),
   cluster_database, role, CDB, name, unique, domain, storage locations with sizes,
   FRA, log_archive_dest_1 location, *_dest directories, TDE wallet, memory parameters.
8. listener port/service from `lsnrctl status <NAME>` run from the listener's own home.

## Standby layout (derived)
- STANDBY_UNIQUE: <PRIMARY_UNIQUE>_STBY (max 12 chars), SID = unique, service = unique[.domain]
- USE_GRID = yes if any primary location is in ASM.
- ASM disks: ASMLib if it works on this kernel, else udev rules keyed on the GPT partition UUID
  (/dev/oraasm/<DG>_<n>). One or more disks per disk group. Labels made by the script (or confirmed
  by the user) are recorded in STATE_DIR/asm_disks; a disk must have an empty first MiB to be offered.
- Filesystem locations: same directories, owner oracle:<install group>, free space checked per mount point.
  Step 2.15 (and again before the duplicate) proves with a test file that they are not the primary's storage.
  Rules (rc 0 not shared, 1 shared, 2 not proven = duplicate refused; shared outranks not proven).
  The primary's mounted file systems are read at every test (probe "mounts": source, UUID, disk ids per file system).
  - shared: a network file system from the same source on both servers; the test file is seen on primary
    (network file systems are asked again after 65 s: client cache); the same UUID on the same disk WWN;
  - not shared: network file system: the test file is not seen after 65 s and the sources differ;
    other file systems: the local UUID is known, the primary shows a UUID for EVERY file system it mounts, this
    UUID is not one of them and no local disk WWN is a disk of the primary;
  - not proven (rc 2) in every other case, e.g. the same UUID (a copy or the same disk: different disk ids do not
    prove two disks), a local disk under a file system of the primary, an incomplete UUID list, the primary user
    cannot look into a network folder (run again with --user <owner>). A confirmation for exactly that disk
    (UUID, else its disk ids, else its device) in STATE_DIR/storage_clone_ok is accepted after the user compared
    the disks in the console.
  - Not covered: a standby file system created on a disk the primary uses for ASM or raw (not mounted there).
- Unzip: a line "title|output|folder" is written to STATE_DIR/unzip_failed before each unzip and removed only
  when the unzip ends with 0 (also when it ended while no run was watching). The installer never starts while
  a line is there.
- Duplicate marker <DB_HOME>/dbs/.dg_duplicate_done_<SID>: "duplicate" (RMAN finished) or "seen" (a mounted
  standby compared with the primary). Either kind counts as complete; either kind plus the
  spfile marks a standby that is shut down as built. A standby once "seen" complete is never offered the
  clean-up/duplicate again; later datafile header errors are only reported.
- Standby listener: always LISTENER, port of the primary.
- RMAN: SET NEWNAME per datafile/tempfile (+DG or the same path), parameters that do not fit are cleared.
- Start at boot: no Grid -> systemd unit (listener, mount, apply, clean stop); Grid -> unit after
  oracle-ohasd that starts apply once Oracle Restart has mounted the standby.

## Software
- Media detected by content: grid image (gridSetup.sh), grid staged (grid/runInstaller, 12.1),
  db image (runInstaller + install/response, 18+), db staged (database/runInstaller, 12.x, may be 2 zips),
  gold image (image built on primary with -createGoldImage, same patches).
- Response file = template shipped in the media, keys set only if present in the template.
- 12.x staged installers: -waitforcompletion. Grid config tools: gridSetup -executeConfigTools (12.2+)
  or cfgtoollogs/configToolAllCommands RESPONSE_FILE=... (12.1).
- Version check: same release (sqlplus -V), same patch ids (folder names in <home>/inventory/oneoffs,
  read on the primary with ls - opatch is not run there because it writes logs).
- Version x OS (step 1.6): 12.x/18c on OL7 only, 19c OL7/8 (CV_ASSUME_DISTID=OEL7.8 on 8+), OL9 with
  RU_DIR (-applyRU), 23ai OL8/9. 12.1 Grid on OL7 needs patch 18370031 before root.sh.
- Installers, root scripts and RMAN run in their own session (setsid) with output in a file shown live;
  a closed terminal does not stop them, the next run waits for them (STATE_DIR/job).

## Admin view across runs
- STATE_DIR/progress: the last result of every step (id|result|time|run|reason). Every run starts with the
  "Where you are" board (one line per phase: DONE / OPEN / PARTLY / -), the last run, the steps not done and
  the --from hint; --status prints it without connecting. STATE_DIR/last_run: when and how the last run ended.
  --status (5.26) puts a Data Guard block on top (dg_status_block: read now, read-only and local, when the
  instance's pmon runs; else the values of STATE_DIR/dg_state_health or dg_state_run with their time) and the
  last --health / phase 10 result with its log; status_runs_block lists the runs behind the step results (from
  the run field of the progress file) with the path of each run log.
- Summary: legend, the reason under every step that is not OK, the changes of the run, "Next: --from X".
- Phase 4: the checks run first and every primary SQL command is printed in ONE box (with "-- undo" lines), so
  the admin goes to the primary once; the steps then pass one by one. The first run offers phase 4 right after
  phase 1 (before the long installs); --only 4 works any time, also while a detached long job runs.
- Primary commands are journaled when their check passes, on every path: every printed primary plan is kept in
  STATE_DIR/primary_pending (step|undo); a later pass of that step (this run or a later one, batch or step by
  step) records DONE_BY_YOU and a PRIMARY journal line with its undo.
- One "Next" rule: RESUME_STEP (set by the step that knows where to go on, for example 7.2 after a failed copy)
  or the first step not done; printed once (summary or stop), also in last_run. --from N (a phase) is printed
  without ".0".
- Waiting steps: when a step (or phase) is not done in this run and the admin goes on, every step that waits
  for it records WAITS without asking again (AUTO_WAIT). A step that names an earlier step which IS done is
  treated as its own problem, not as a wait.
- A step that could not do its check is never OK (5.12): the check sets CHECK_WAITS=1 (recorded WAITS, checked
  again later, for example the logins of a built standby that is down) or, for an optional step, CHECK_WAITS=2
  (recorded skipped, optional; on a step that is not optional it is WAITS, 5.13); otherwise it returns 2 ("cannot
  be checked"), which asks [r]/[s] in a run and is a PROBLEM in --check. The check after an action follows the same
  rule. A step whose own subject is fine but which tests something it depends on (9.2 / 9.4 testing the deferred
  logins) waits while that test cannot run.
- What a step set up is also checked for what it started (5.13): 9.7 starts a stopped listener or apply as its
  action (asked first); a wrong role is only reported. 9.3 starts apply again when it stopped it. 8.2 looks at the
  new standby after RMAN reports success. 10.2 and 10.3 check again 6 times (DG_POLL_WAIT seconds, default 20).
- Edits inside existing files (5.13): only when the structure is unambiguous (one entry or block, parentheses that
  close), always with a backup and a journal entry; otherwise the plan is manual. listener.ora: a SID_DESC is put
  inside SID_LIST_<listener>, or (5.14) the wrong SID_DESC of this SID is replaced when it stands on lines of its
  own; tnsnames.ora (5.14): a wrong alias entry is replaced when it starts on its own line and nothing follows its
  closing parenthesis; sqlnet.ora: the one ENCRYPTION_WALLET_LOCATION entry is replaced, its comments kept as
  comment lines above it.
- Links (5.14): listener.ora, tnsnames.ora and sqlnet.ora that are symbolic links are never written through (found
  in the check, manual plan). /etc/oratab as a link is written through only when safe_link_target accepts it: the
  link owned by root, the target a regular file of root or an Oracle owner, every folder above it owned by root and
  writable only by root.
- Folders (5.18): make_dir acts as root (install -d, chown, chmod) only while no one but root can change the
  folders on the way down from / (root_holds: owned by root and not writable by group or others, or sticky with the
  next part already root's). Below the first folder another user can change, the rest is made as the future owner
  (runuser mkdir), and the mode of an existing empty folder is set as that owner. 7.1 shows a root mkdir/chown for
  an audit_file_dest outside the Oracle base only under the same condition, for the resolved path, which must pass
  v_path again; otherwise the oracle user makes it, or the path is refused with the reason.
- Programs of an Oracle home run as root (5.19): root.sh, orainstRoot.sh, crsctl start has and setasmgidwrap are
  required by Oracle and cannot be avoided. root_prog_ok runs them only when the file and its folder are not links,
  belong to root, oracle or grid, are not writable by others, and are group-writable only for the install group.
  Files root puts into folders of oracle (password file, wallet) are written by oracle itself (install_as); the undo
  of a file in a folder of oracle or grid is done as that user.
- --health (5.20): the checks of phase 10 for cron or a monitoring agent (src/85_health.sh). MODE=check, no
  terminal, no prompt (every prompt function ends the run as UNKNOWN), its own lock attempt (busy: UNKNOWN), its
  own log (health_<run>.log, 640, kept 14 days), its own ssh master opened with BatchMode=yes (a key only; the
  interactive master is never touched) and its own memory of Data Guard errors. The instance is checked first
  (down: CRITICAL, nothing else). Checks are called directly, not through run_step (no progress record). A
  problem in 10.1-10.4 is checked once more after 60 seconds. Exit 0 OK, 1 WARNING, 2 CRITICAL, 3 UNKNOWN
  (worst first: CRITICAL, UNKNOWN, WARNING; SKIPPED counts as nothing); a start failure, a wrong option or
  fatal() give 3.
- --health output (5.26): the lines are kept (health_out) and printed at the end, so the FIRST line is the status
  in Nagios form: "STATE - summary | transport_lag=Ns;;LIM;0 apply_lag=Ns;;LIM;0" (the worst check with its text,
  "(+N more not OK)", the lag from 10.1, the protection mode, "primary not checked (no ssh key)"). Then the
  title, the check lines, a "Data Guard:" line (dg_state_read: role, open mode, protection mode, MRP, last
  applied log; read-only on the standby), notes, and "Result: ...". The values are also kept for --status in
  STATE_DIR/dg_state_health (and dg_state_run by the end of phase 10 in a normal run): key=value lines, read back
  by a parser (dg_state_load), never sourced.
- No key for the primary (5.26): when the health master gets "Permission denied", HEALTH_SSH_NOKEY=1 and the
  primary is "not checked", which is not UNKNOWN: 10.3 and 10.5 run on the standby side only (c_10_3_sb: last
  log received per thread in v$archived_log against the last applied, plus the apply lag; c_10_5_sb: the
  standby's v$nonlogged_block, 12.1: SKIPPED), and 10.6 is SKIPPED. Any other ssh failure stays UNKNOWN for them.
- Step 9.9 (5.26, optional): the key for --health, STATE_DIR-independent at /root/.ssh/dg_health_<unique>
  (DG_SSH_DIR moves the folder, for the tests). Check: the key and .pub exist, root owns it, mode 600, and a
  BatchMode master to the primary opens with it (health_key_test: its own control path, the same host-key
  options as every connection). Action: ssh-keygen (Will run), journaled NEW (--undo 9.9 removes it). Then a
  primary box (as the ssh user) with mkdir/chmod/echo/chmod of the restricted authorized_keys line
  (from="<standby ip>",no-port-forwarding,no-X11-forwarding,no-agent-forwarding,no-pty), PLAN_UNDO names the
  line. health_ssh and health_key_test pass -o IdentityFile=<key> when the file exists.
- Help (5.26): show_help prints the RUN part as one block between two rules, commands at column 0
  (help_cmd_block): explanations become "# " lines ("-- " between a line that starts sqlplus/rman and "exit"),
  a trailing "      (note)" goes on its own line above its command. The prose is recognised by its form (a
  capital first word, a line ending in ":", "(text ...)", a table row, the continuation of a sentence); a new
  help text keeps commands lower case at the start and prose as sentences.
- 10.1 also reads datum_time (no data from the primary for longer than the limit is a problem even with lag 0)
  and, when the lag is high, the primary's destination for this standby (gv$archive_dest, read-only).
- 10.5: v$nonlogged_block on the standby (12.2+) is the proof; force logging of the primary is advice
  (WARNING); STANDBY NOLOGGING modes are accepted. 12.1: force logging only.
- 10.6: patch folders of the database home here and on the primary (read-only); a difference is a WARNING.
- dg_error_hint: known ORA- codes in 10.1 / 10.4 messages get one line with the usual cause and the step.
- --roll-forward (10.7, 18c+): RECOVER STANDBY DATABASE FROM SERVICE, as a long job. Refused unless the standby
  is mounted, no RMAN session or long job runs, the broker is off on the standby, RMAN logs in to both, the
  listener has a static entry, an encrypted standby has an auto-login wallet, and RMAN can find the standby's
  datafiles again (same names, db_file_name_convert, or all OMF under db_create_file_dest). Journal: ROLLFWD
  (nothing to undo). 12.x: the manual way is shown.
- Copy (8.2): SECTION SIZE (automatic 32G when a datafile is 64 GB or more and AUX_CHANNELS > 1; setting
  DUP_SECTION_SIZE) with one explicit channel on the primary, so the auxiliary channels outnumber it.
- Boot script (5.14): it never starts apply on an OPEN standby (Active Data Guard). Its errors carry the "<3>"
  prefix (journal priority err, for monitoring). The unit stays active after an error on purpose: a failed unit
  does not run ExecStop, and the stop is the clean shutdown of the standby.
- /dev/shm boot size (5.14): with systemd running, "systemctl cat dev-shm.mount" (the last Options line wins, also
  in /run and /usr/lib). A file outside /etc is never changed; an /etc drop-in zz-dg-standby-shm.conf sets the size.
- Tests (5.15): the harness runs the script with DG_TEST_FAST_WAITS=1 (every nap is 0.2 s; the mocks answer at
  once). A full regression runs once, at the end of a version; the GitHub copy gets a short smoke run.
- Release Update identity (5.14): RU_DIR is the numbered folder (or holds exactly one); one of its patches must be
  on the primary's database home and, with Grid, its Grid home; only the home being installed is compared (5.15). Checked in 3.1 when an install is pending, and
  again in 3.2 and 3.6 before the installer runs.
- Long jobs: Ctrl+C asks [w] keep watching / [d] leave it running; the step is recorded RUNNING, the stop text
  says not to start it again, --status shows "Running now". A job that ends while no run watches is recorded
  by the next run (installer success records, root.sh, unzip, the duplicate with its pfile rename), journaled
  under the step that started it. --check while a job runs judges phase 3 (installers) or 7 (duplicate) and
  later as WAITS. Check mode writes nothing to the progress or last-run files (only its log): they keep the
  results of the real runs.
- After a failed duplicate only [q] is offered: 7.2 shows the clean-up (instance from the leftover spfile,
  files of the failed copy); 8.1 refuses a dirty auxiliary.
- Questions: 1.2, 1.3 and 1.5 ask nothing but the passwords; the saved PRIMARY_SID is reused; the ORACLE_HOME
  comes from the process environment or the inventory before anyone is asked; listener values that were only
  assumed are marked and may be corrected in 1.4; typed words are case-insensitive with three tries.

## Change journal and undo (15_journal.sh)
- Every change on the standby is a line in STATE_DIR/changes.log: seq|time|run|step|kind|object|detail.
  Kinds: NEW/EDIT/APPEND/RENAME (files; APPEND keeps offset, length and md5 of the added block), DIR, GROUP, USER,
  USERMOD, PKG, FWPORT, SERVICE, ASMCFG, SETTING, PART, ASMLABEL, UNZIP, SOFTWARE, GRIDCONFIG, ASMINST, DISKGROUP,
  ROOTSH, ROOHCTL, LSNRRES, LSNRPORT, LSNRSTART, INSTANCE, DUPLICATE/DUPLICATE_DONE, SRVCTL, SRL (group numbers),
  MRP, UNIT, RMANCFG, OPATCH, SRVCTL_OLD, PRIMARY (a command the admin ran on the primary, with its undo text).
  The first line is "#journal v1"; readers skip lines whose seq is not a number. A write failure warns once.
- Undo checks every field again before using it (paths, unit and listener names, backup names, the SID of the
  current settings), refuses to run when the settings do not load, treats "already gone" as done, cuts exactly
  the appended bytes (and removes a file that only held them), drops SRLs with standby_file_management MANUAL,
  records the step UNDONE on the progress board, and lets the admin mark a line handled by hand. --undo goes
  alone (no --check/--status/--from/--only).
- --show-changes [STEP] lists them with the undo of each; --undo STEP walks one step backwards, asks before
  every change, undoes files (restore / cut the appended block / remove), firewall ports, units (disable only),
  listener resources, instance, registration, SRLs, MRP; disks, software, users, the copied database and
  primary commands are printed for the admin. A step with later active steps needs the typed word UNDO.
- Installers write a success record (STATE_DIR/*_install.done, grid_config.done); an inventory entry without
  it is HALF_INSTALLED and the admin decides (touch the record, or deinstall).

## Step engine
check (read-only) -> show Now / Plan / Using -> ask -> do -> check again -> result.
Failures show the step's manual commands. rc 2 = cannot continue automatically (manual block),
or "waits for step X" when the message names an earlier step. Check mode: TODO / WAITS / PROBLEM.
Settings: primary values are read at every run; only standby values can be edited; the accepted
values are kept in settings.accepted and differences are shown. One run at a time (flock).
