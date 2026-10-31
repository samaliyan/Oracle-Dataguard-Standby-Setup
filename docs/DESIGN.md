# dg_standby_setup.sh 5.0 - design

Runs as root on the future STANDBY. Builds a physical standby of one primary database.
Never changes the primary: primary work is printed, then re-checked read-only.

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
