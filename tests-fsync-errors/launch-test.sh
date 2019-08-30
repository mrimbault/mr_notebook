#!/bin/bash
#------------------------------------------------------------------------------
# Inspired by: https://github.com/ringerc/scrapcode/blob/master/testcases/
#------------------------------------------------------------------------------

set -e -u -x

echo "
=========================================================
WARNING: this script is intended for experiments purpose.
Running it on live systems will destroy or corrupt data.
=========================================================
"
echo "The following environment will be wiped out and used for the tests:"
echo "- PGDATA: ${PGDATA}"
# FIXME add some more details
# FIXME do not rely on env variables like PGDATA, force using explicit
# arguments to avoid the script being run on a wrong environment


if [ -z "$1" ] || [ "$1" != "--run" ]; then
    echo "
If you seriously intend to run this script despite the previous warning, try
again with \"--run\" option.
Exiting for now.
"
    exit 1
fi

shift

if [ "$1" != "--force-run" ]; then
    echo "Do you really want to run the tests on this environement?"
    select yn in "Yes" "No"; do
        case $REPLY in
            1|"Yes") break;;
            2|"No") exit;;
            *) echo "Choice \"$yn\" or answer \"$REPLY\" is invalid.";;
        esac
    done
else
    shift
fi

# Setup variables and args.
scenario="${1:-1}"
# FIXME change mountpoint depending on scenario
# FIXME pass as an argument
tbs_dir="${2:-/mnt/error_mount/data}"

set_default_sysctl() {
    # Ensure normal FS cache cleanup.
    sysctl_conf="
vm.dirty_background_bytes = 0
vm.dirty_bytes = 0
vm.dirty_background_ratio = 10
vm.dirty_ratio = 30
vm.dirty_writeback_centisecs = 500
vm.dirty_expire_centisecs = 3000"
    sudo sh -c "echo '$sysctl_conf' | sysctl -p-"
}

set_aggressive_sysctl() {
    # FIXME should dirty_ratio/bytes also be aggressive here, or would that be
    # pointless apart from slowing down testing?
    sysctl_conf="
vm.dirty_background_ratio = 0
vm.dirty_ratio = 0
vm.dirty_background_bytes = 4096
vm.dirty_bytes = 8192
vm.dirty_writeback_centisecs = 100
vm.dirty_expire_centisecs = 500"
    sudo sh -c "echo '$sysctl_conf' | sysctl -p-"
}

prepare_instance() {
    # Cleanup.
    # Stop PostgreSQL if running.
    pg_ctl -D "$PGDATA" -w -m immediate stop || true
    # Remove an existing instance.
    rm -rf "${PGDATA:?}"/*
    rm -rf "${tbs_dir:?}"/*
    # Create intance with default configuration.
    # FIXME add an option to enable checksums or other options?
    initdb
    # Start the instance.
    pg_ctl -D "$PGDATA" start -l "${PGDATA}/startup.log"
    # Configure instance.
    # FIXME several parameters (like statement_timeout or checkpoint_timeout?)
    # should be configurable
    # FIXME add statement_timeout for insert into filltable?
    # FIXME setup everything on configuration files for scenarios?
    # FIXME WARN: what about xlog triggered checkpoints?  Is 5GB high enough?
    # FIXME WARN: should we ensure that insert into filltable is done before
    # the next checkpoints STARTS?
    # FIXME IMPORTANT: we need to ensure that the "corrupted blocks" are the
    # oldest dirty blocks on the shared buffers at checkpoint start (FIXME does
    # that have any importance?  how does the checkpoint order the buffers to
    # be synced?)
    # FIXME check bgwriter configuration
    # FIXME checkpoint_completion_target is setup to 0.5 so that 50% of the
    # time will be used to modify buffers, and no modification will occur
    # during checkpoints.  Hopefully that should help analysis.
    psql <<EOF
ALTER SYSTEM SET logging_collector = on;
ALTER SYSTEM SET log_destination = 'stderr, csvlog';
ALTER SYSTEM SET log_filename = 'postgresql.log';
ALTER SYSTEM SET log_checkpoints = on;
--ALTER SYSTEM SET log_connections = on;
--ALTER SYSTEM SET log_disconnections = on;
ALTER SYSTEM SET log_error_verbosity = verbose;
ALTER SYSTEM SET max_wal_size = '5GB';
ALTER SYSTEM SET autovacuum = off;
EOF
    # Restart the instance.
    pg_ctl -D "$PGDATA" restart -l "${PGDATA}/startup.log"
    # Create tablespace and required relations.
    psql <<EOF
-- Tablespace using mount point causing errors as location.
CREATE TABLESPACE mytbs LOCATION '${tbs_dir}';
-- Table to insert data that will trigger errors.
-- The size of the attributes (478 bytes, including the int key and the char
-- type 4 bytes overhead) has been selected so we can efficiently fill data
-- blocks to maximize chances to encounter corruptions, and keep things
-- predictable (including avoiding using TOAST).  So, including block header,
-- tuple headers, and 16 tuples per block, that gives us:
-- ( 24 + ( 16 * ( 36 + 474 ) ) ) = 8184
-- Just 8 bytes under PostgreSQL default block size.
CREATE TABLE errtable(
    id serial primary key,
    padding char(470) NOT NULL
) TABLESPACE mytbs;
-- Table referencing rows from the table triggering errors, so we can identify
-- corrupted lines afterwards.
CREATE TABLE reftable(
    refid int REFERENCES errtable(id),
    checkpoint_lsn pg_lsn,
    insert_time timestamptz DEFAULT clock_timestamp(),
    insert_lsn pg_lsn DEFAULT pg_current_wal_insert_lsn()
);
-- Table used to store checkpoints details.
CREATE TABLE checkpoint_log(
    checkpoint_lsn pg_lsn,
    redo_lsn pg_lsn,
    checkpoint_time timestamptz,
    capture_time timestamptz DEFAULT clock_timestamp()
);
-- Table used to store information if pg_resetwal is used.
CREATE TABLE resetwal_log(
    resetwal_lsn pg_lsn,
    resetwal_time timestamptz,
    capture_time timestamptz DEFAULT clock_timestamp()
);
-- Table used to store events from PostgreSQL csv logs (see:
-- https://www.postgresql.org/docs/current/runtime-config-logging.html#RUNTIME-CONFIG-LOGGING-CSVLOG).
CREATE TABLE postgres_log(
    log_time timestamp(3) with time zone,
    user_name text,
    database_name text,
    process_id integer,
    connection_from text,
    session_id text,
    session_line_num bigint,
    command_tag text,
    session_start_time timestamp with time zone,
    virtual_transaction_id text,
    transaction_id bigint,
    error_severity text,
    sql_state_code text,
    message text,
    detail text,
    hint text,
    internal_query text,
    internal_query_pos integer,
    context text,
    query text,
    query_pos integer,
    location text,
    application_name text,
    PRIMARY KEY (session_id, session_line_num)
);
-- Table used to store events from system kernel logs.
CREATE TABLE system_log(
    realtime_timestamp bigint,
    priority smallint,
    message text
);
-- Force initial checkpoint to ensure that a following crash and resetwal would
-- not remove table schema.
CHECKPOINT;
EOF
}

# Execute a query on PostgreSQL instance, and return the results to caller.  If
# the query fails, check whether this is a temporary failure, or a persistent
# one that can be resolved, and in either case obstinately retries the query,
# even if it means corrupting the instance (resetwal) to do so.
stubborn_query() {
    psql_args=( "$@" )
    stdin="$(cat -)"
    RECOVER_TIMEOUT="10"
    elapsed=0
    while ! echo "$stdin" | psql "${psql_args[@]}" 2>/tmp/psql.err; do
        # Executing the command failed.  In this test context, that probably
        # means the PostgreSQL instance is not responsive due to a PANIC
        # failure.  We first wait for it to recover by itself (that is not very
        # probable).
        sleep 1
        (( ++elapsed ))
        if [ "$elapsed" -gt "$RECOVER_TIMEOUT" ]; then

            # If we waited that long, we decide to forcefully restart the
            # PostgreSQL instance using pg_resetwal.
            # First, we stop PostgreSQL if it is still running.
            pg_ctl -D "$PGDATA" -w -m immediate stop || true

            # Remove pidfile if exists.
            if [ -f "${PGDATA}/postmaster.pid" ]; then
                rm "${PGDATA}/postmaster.pid"
            fi

            # Then, we force a reset of WAL files so PostgreSQL will "forget"
            # about any WAL entry that can not be replayed.  We do corrupt our
            # data while doing this...  all for the sake of testing whether
            # data where lost before any checkpoint that preceeded this last
            # failed checkpoint.  Obviously, corrupted data that appeared
            # immediately before the failed checkpoint that triggered the PANIC
            # should not be considered an anomaly: having forced pg_resetwal,
            # we are responsible for this.
            pg_resetwal -f "$PGDATA"

            # Get resetwal LSN and time, so we can insert this into the
            # resetwal_log table and keep track of the action.
            resetwal_lsn="'$(LC_ALL=C pg_controldata "$PGDATA" | sed -n 's/^Latest checkpoint location:\s\+\(.*\)$/\1/p')'"
            resetwal_time="'$(LC_ALL=C pg_controldata "$PGDATA" | sed -n 's/^Time of latest checkpoint:\s\+\(.*\)$/\1/p')'"

            # Start PostgreSQL and wait for startup to finish.
            pg_ctl -D "$PGDATA" -w start -l "${PGDATA}/startup.log"

            if [ -n "$do_filldata" ]; then
                # FIXME truncate filltable after this, to avoid side effect of the
                # resetwal
                psql -At <<EOF
TRUNCATE filltable;
EOF
            fi

            if [ -n "$do_filltables" ]; then
                # FIXME re-create filltables after this, to avoid side effect of
                # the resetwal (corrupted catalog pointing on non-existant tables).
                # FIXME note that we may also have orphaned files
                # FIXME this is way too long
                # FIXME end with a forced checkpoint?
                # FIXME errors:
#NOTICE:  table "filltable_2972" does not exist, skipping
#DROP TABLE
#ERROR:  type "filltable_2972" already exists
                relcount=1
                while [ "$relcount" -le "$relations_to_fill" ]; do
                    psql -At <<EOF
DROP TABLE IF EXISTS filltable_${relcount};
CREATE TABLE filltable_${relcount}(padding char(474) NOT NULL);
EOF
                    (( ++relcount ))
                done
                # vacuum critical catalog tables to avoid excess bloating due to
                # many relations dropped/created
                psql -Atc "VACUUM pg_catalog.pg_class"
                psql -Atc "VACUUM pg_catalog.pg_attribute"
                psql -Atc "VACUUM pg_catalog.pg_type"
                psql -Atc "VACUUM pg_catalog.pg_depend"
            fi

            # FIXME is this usefull? it will reset the checkpoint timeout
            # counter ... but maybe that is better
            psql -Atc 'CHECKPOINT'

            # Copy resetwal informations to keep track of what happened here
            # during analysis (corruptions caused by usage of pg_resetwal
            # should not be grouped with undetected corruptions).
            # NOTE: We artificially remove 1 microsecond to the resetwal
            # timestamp so it will always appear as if it occured before the
            # checkpoint registered into checkpoint_log.  That allows to
            # correctly associate the resetwal with the checkpoint when
            # aggregating events during analysis.
            psql -v "lsn=${resetwal_lsn}" -v "time=${resetwal_time}" -At <<EOF
COPY ( VALUES (PG_LSN :lsn, TIMESTAMPTZ :time  - INTERVAL '1microsecond') )
TO PROGRAM 'cat - >> ${collect_dir}/resetwal_log.dump';
EOF
            # Reset elapsed counter.
            elapsed=0
        fi
    done
}

# FIXME is this necessary?  Is this dependant en the FS used (XFS, EXT4, etc.)?
pre_insert_data() {
    # Insert data to quickly fill the begining of a FS raising errors, and get
    # to the position errors will be more likely to appear.
    # FIXME first test: logical block 14330
    # FIXME second test: size was 2344 kB, logical block 14334
    # FIXME set a variable for this, depending on FS used?
    # FIXME raise work_mem for generate_series?
    stubborn_query -v "lines=${PREFILL_LINES_COUNT}" -At <<EOF
WITH inserted AS (
    INSERT INTO errtable (padding)
    SELECT ('blanks follow:')
    FROM generate_series(1,:lines)
    RETURNING id)
INSERT INTO reftable(refid, checkpoint_lsn)
SELECT i.id, c.checkpoint_lsn FROM inserted i, pg_control_checkpoint() c;
CHECKPOINT;
EOF
}

insert_data() {
    # Insert just enough lines to fill several data blocks.  To help
    # diagnostics, also save current timestamp and LSN (reftable columns
    # default value) and latest started checkpoint LSN.
    # This is the insertion that should ultimately write to bad blocks, and
    # trigger writeback errors... but the insertion itself should succeed, it's
    # the next occuring checkpoint that needs to fail.
    stubborn_query -v "lines=${ERROR_LINES_COUNT}" -At <<EOF
-- Avoid query failing on read errors.
SET zero_damaged_pages = ON;
WITH inserted AS (
    INSERT INTO errtable (padding)
    SELECT ('blanks follow:')
    FROM generate_series(1,:lines)
    RETURNING id)
INSERT INTO reftable(refid, checkpoint_lsn)
SELECT i.id, c.checkpoint_lsn FROM inserted i, pg_control_checkpoint() c;
EOF
}

prepare_filltables() {

    # FIXME create all "relations to fill"
    # FIXME this is way too long
    #       ~20 min for 80640 tables
    relcount=1
    while [ "$relcount" -le "$relations_to_fill" ]; do
        psql -Atc "CREATE TABLE filltable_${relcount}(padding char(474) NOT NULL)"\
            && (( ++relcount ))
    done
    # FIXME is this necessary?
    psql -Atc 'CHECKPOINT'

}

fill_tables() {
    # Run queries that use up the server's memory, so that the operating system
    # will have to writeback dirty blocks to storage.  The purpose is to have
    # background OS process sync the corrupted dirty blocks and raise IO errors
    # as soon as the checkpointer write it to FS memory.  This way, we can test
    # if the checkpointer also gets an error when it starts fsyncing.
    # FIXME TODO
    #       use something like pgbench, with a high memory consumption query?
    #       or perhaps a high work_mem conf and very big sorts, to force
    #         swaping memory?
    # FIXME possibilities:
    # - fill shared_buffers with other (sane) dirty blocks, but do not exceed
    #   shared buffers size to avoid having a backend force sync the bad blocks
    #   (or force reads on these blocks to keep the usagecount high?
    # - fill and overloads the shared_buffers to test the behaviour when a
    #   backend has to sync the bad blocks (and thus captures the error before
    #   the checkpointer)
    # - saturate the server RAM ... will a low shared_buffers (up to 25% RAM),
    #   be enough to trigger the writeback and the background error?  Probably
    #   configurable using dirty_background_ratio/bytes.  We should also test
    #   with shared_buffers > 75% RAM (so one checkpoint can easily saturate FS
    #   caches without triggering backends sync).
    # FIXME we need to be able to compute the data volume to be inserted based on:
    # - shared_buffers size (so we can adapt modified data volume to avoid
    #   having backends trigger fsync)
    # - server RAM size (to try to saturate FS cache)
    # FIXME we may need to raise max_wal_size to avoid non-timed checkpoints
    # FIXME we should try to insert very long lines, to minimize the variations
    # caused by tuple headers ... but what about TOAST?

    # FIXME should we lauch this using pgbench, with multiple concurrent
    # sessions?
    # FIXME should we monitor shared buffers contents using pg_buffercache?
    # Table used to saturate memory with dirty buffers, without causing I/O
    # errors.  We create a new table and try to drop the previous one before
    # inserting.  We cannot just truncate and use the same one because we may
    # use pg_resetwal if we PANIC, and that may leave us with an orphaned
    # Shrödinger's table, already dropped and already created at the same time
    # (obviously, that's because the catalog is corrupted, but having used
    # pg_resetwal that was to be expected).  So it is best to abandon the old
    # table if it can not be dropped, and move to a new one.

    # FIXME TRUNCATE is used here to "burn" file descriptors, and help to
    # trigger the "silent" error
    # FIXME is there a threshold to trigger file descriptor cache reuse?

    # FIXME warning, failure and resewal can leave us in a very incoherent
    # state here, with orphaned files and corrupted catalog pointing on non
    # existant files...
    # FIXME this is very, very long (~20 min. for 80640 tables)
    relcount=1
    while [ "$relcount" -le "$relations_to_fill" ]; do
        stubborn_query -At <<EOF
TRUNCATE filltable_${relcount};
INSERT INTO filltable_${relcount} (padding)
    SELECT ('blanks follow:')
    FROM generate_series(1,16);
EOF
    (( ++relcount ))
    done
    # vacuum critical catalog tables to avoid excess bloating due to many
    # relations truncated
    stubborn_query -At <<EOF
VACUUM pg_catalog.pg_class;
VACUUM pg_catalog.pg_attribute;
VACUUM pg_catalog.pg_type;
VACUUM pg_catalog.pg_depend;
EOF
    # ~ 35 min

}

# FIXME same that "full_tables", using DELETE instead of TRUNCATE
# FIXME very, very slow, and seems kinda useless
fill_tables_delete() {
    relcount=1
    while [ "$relcount" -le "$relations_to_fill" ]; do
        stubborn_query -At <<EOF
DELETE FROM filltable_${relcount};
VACUUM filltable_${relcount};
INSERT INTO filltable_${relcount} (padding)
    SELECT ('blanks follow:')
    FROM generate_series(1,16);
EOF
    (( ++relcount ))
    done

}


is_next_checkpoint_far() {

	# FIXME query used to estimate if the next checkpoint is near starting its
	# work
	result=$(stubborn_query -At <<EOF
WITH settings AS (
    SELECT round (
            (
                string_agg(setting, '')
                FILTER (WHERE name='checkpoint_timeout')
            )::int * (
                string_agg(setting, '')
                FILTER (WHERE name='checkpoint_completion_target')
            )::double precision
        )::text::interval AS estimated_checkpoint_duration
    FROM pg_settings
)
SELECT now() < ( checkpoint_time + estimated_checkpoint_duration )
FROM pg_control_checkpoint(), settings;
EOF
	)
	[ "$result" = "t" ]
	return $?

}

write_many_files_before_chkp() {

    i=0
    # Cleanup temp files dir.
    rm "${tmpfilesdir}/*" || true
    # FIXME also check for FS full?
    while is_next_checkpoint_far; do
        dd if=/dev/zero of="${tmpfilesdir}/tmp_${i}" bs=8182 count=1
        (( ++i ))
    done

    # FIXME Force a manual sync to try to capture every fsync errors before
    # PostgreSQL can run a checkpoint?
    sudo sync || true

}

# FIXME probably completely wrong
is_checkpoint_running() {

	# FIXME query used to estimate if the next checkpoint is near starting its
	# work
	result=$(stubborn_query -At <<EOF
WITH settings AS (
    SELECT
        (
            string_agg(setting, '')
            FILTER (WHERE name='checkpoint_timeout')
        )::int AS checkpoint_timeout,
        round (
            (
                string_agg(setting, '')
                FILTER (WHERE name='checkpoint_timeout')
            )::int * (
                string_agg(setting, '')
                FILTER (WHERE name='checkpoint_completion_target')
            )::double precision
        )::text::interval AS estimated_checkpoint_duration
    FROM pg_settings
)
SELECT
    now() > ( checkpoint_time + ( checkpoint_timeout - estimated_checkpoint_duration ) )
    AND now() < ( checkpoint_time + checkpoint_timeout )
FROM pg_control_checkpoint(), settings;
EOF
	)
	[ "$result" = "t" ]
	return $?

}

# FIXME probably completely wrong
write_many_files_during_chkp() {

    i=0
    # Cleanup temp files dir.
    rm "${tmpfilesdir}/*" || true
    # FIXME also check for FS full?
    while is_checkpoint_running; do
        dd if=/dev/zero of="${tmpfilesdir}/tmp_${i}" bs=8182 count=1
        (( ++i ))
        # FIXME Force a manual sync to try to capture every fsync errors before
        # PostgreSQL can run a checkpoint?
        #sudo sync || true
    done

}

prepare_filldata() {

    # Create table to generate dirty blocks and add memory pressure.
    psql -At <<EOF
CREATE TABLE filltable(
    padding char(474) NOT NULL
);
EOF

}

fill_data() {

    # Insert data on a single table without generating errors to apply pressure
    # on memory and cause writeback.
    stubborn_query -v "lines=${lines_to_fill}" -At <<EOF
DELETE FROM filltable;
VACUUM filltable;
INSERT INTO filltable (padding)
    SELECT ('blanks follow:')
    FROM generate_series(1,:lines);
EOF

}

# Create the C function used to burn fd during tests.
prepare_burnfd() {

    # FIXME for now, this requires sudo for postgres user to write into this
    # folder...  deal with this so sudo is not necessary
    shared_dir="/share"
    include_dir="$(pg_config --includedir)/server"
    pg_lib_dir="$(pg_config --pkglibdir)"
    (
        cd "$shared_dir" &&
        sudo cc -I"$include_dir" -fPIC -c burn_fd.c &&
        sudo cc -shared -o burn_fd.so burn_fd.o &&
        cp burn_fd.so "$pg_lib_dir"
    )
    psql -At <<EOF
CREATE FUNCTION burn_fd(integer) RETURNS void
     AS 'burn_fd'
     LANGUAGE C STRICT;
EOF

}

burn_fd() {

    # Execute a C function to burn FD as fast as possible.
    stubborn_query -At <<EOF
SELECT burn_fd(80640);
EOF

}



wait_checkpoint() {
    # Get latest checkpoint LSN from data inserted into reference table.
    last_chkp_lsn=$(echo "SELECT checkpoint_lsn FROM reftable ORDER BY refid DESC LIMIT 1;" | stubborn_query -At)
    curr_chkp_lsn=$(echo "SELECT checkpoint_lsn FROM pg_control_checkpoint();" | stubborn_query -At)
    while [ "$last_chkp_lsn" == "$curr_chkp_lsn" ]; do
        sleep 1
        curr_chkp_lsn=$(echo "SELECT checkpoint_lsn FROM pg_control_checkpoint();" | stubborn_query -At)
    done
    # Save latest checkpoint informations to keep history.
    stubborn_query -At <<EOF
COPY (
    SELECT checkpoint_lsn, redo_lsn, checkpoint_time
    FROM pg_control_checkpoint()
) TO PROGRAM 'cat - >> ${collect_dir}/checkpoint_log.dump';
EOF
}


enable_traces() {

    # Remove all previous audit traces and all previous audit trace files.
    sudo auditctl -D
    sudo sh -c "rm -f /var/log/audit/* || true"
    sudo systemctl restart auditd.service

    # Get relfilenode path for the error table.
    filepath=$(psql -At <<EOF
SELECT regexp_replace(
    pg_relation_filepath('errtable'),
    '^pg_tblspc/[[:digit:]]+/',
    '${tbs_dir}'
);
EOF
)

    # Create a new audit trace for all syscalls on the file.
    sudo auditctl -w "$filepath" -k trace_errtable_file

    # Create a new audit trace for all sync syscalls on the filesystem.
    sudo auditctl -a always,exit -F arch=b64 -S sync -S fsync -S msync \
        -S fdatasync -S sync_file_range -S syncfs -F dir="$tbs_dir" \
        -k trace_sync

    # Enable kernel traces on IO related events.
    # FIXME warning:
    #[Sun Jul 28 18:16:26 2019] Scheduler tracepoints stat_sleep, stat_iowait,
    #stat_blocked and stat _runtime require the kernel parameter
    #schedstats=enable or kernel.sched_schedstats=1
    sudo sh -c 'echo 1 > /sys/kernel/debug/tracing/events/block/enable'
    # FIXME should choose depending on FS type
    sudo sh -c 'echo 1 > /sys/kernel/debug/tracing/events/xfs/enable'
    sudo sh -c 'echo 1 > /sys/kernel/debug/tracing/events/jbd2/enable'
    sudo sh -c 'echo 1 > /sys/kernel/debug/tracing/events/mmc/enable'
    sudo sh -c 'echo 1 > /sys/kernel/debug/tracing/events/sched/enable'
    sudo sh -c 'echo 1 > /sys/kernel/debug/tracing/events/workqueue/enable'
    sudo sh -c 'echo 1 > /sys/kernel/debug/tracing/tracing_on'

}

disable_traces() {

    # Disable kernel traces on IO related events.
    sudo sh -c 'echo 0 > /sys/kernel/debug/tracing/events/block/enable'
    # FIXME should choose depending on FS type
    sudo sh -c 'echo 0 > /sys/kernel/debug/tracing/events/xfs/enable'
    sudo sh -c 'echo 0 > /sys/kernel/debug/tracing/events/jbd2/enable'
    sudo sh -c 'echo 0 > /sys/kernel/debug/tracing/events/mmc/enable'
    sudo sh -c 'echo 0 > /sys/kernel/debug/tracing/events/sched/enable'
    sudo sh -c 'echo 0 > /sys/kernel/debug/tracing/events/workqueue/enable'
    sudo sh -c 'echo 0 > /sys/kernel/debug/tracing/tracing_on'

}


launch_scenario() {

    enable_traces

    # Log the last successfull checkpoint, before testing starts.
    stubborn_query -At <<EOF
COPY (
    SELECT checkpoint_lsn, redo_lsn, checkpoint_time
    FROM pg_control_checkpoint()
) TO PROGRAM 'cat - >> ${collect_dir}/checkpoint_log.dump';
EOF
    # Actually launch the test using scenario configuration.
    test=1
    while [ "$test" -le "$TEST_COUNT" ]; do
        # Execute simple insert SQL query, increment count only if query
        # succeeded.
        insert_data && (( ++test ))
        # FIXME conditional and bool GUC here?
        [ -n "$do_filldata" ] && fill_data
        [ -n "$do_filltables" ] && fill_tables
        [ -n "$do_filltablesdelete" ] && fill_tables_delete
        [ -n "$do_burnfd" ] && burn_fd
        [ -n "$do_writemanyfilesbeforechkp" ] && write_many_files_before_chkp
        [ -n "$do_writemanyfilesduringchkp" ] && write_many_files_during_chkp
        # FIXME capture memory and fs infos and insert these into PostgreSQL
        # log tables to keep tracks of the evolution during the tests?
        grep -e "Dirty:" -e "Writeback:" /proc/meminfo
        df -h "$tbs_dir"
        # Wait until next checkpoint (or PG crash).
        wait_checkpoint
    done

    disable_traces

}

# Load events related to the test to various tables so analysis can be done.
load_events() {
    # Extract all relevant information for full report.
    # Import checkpoint history.
    psql <<EOF
COPY checkpoint_log(checkpoint_lsn, redo_lsn, checkpoint_time)
FROM '${collect_dir}/checkpoint_log.dump';
EOF
    # Import resetwal history.
    # FIXME this file may not exist if no resetwal occured
    psql <<EOF
COPY resetwal_log(resetwal_lsn, resetwal_time)
FROM '${collect_dir}/resetwal_log.dump';
EOF
    # Import relevant PostgreSQL logs from the csv log file, ignoring whatever
    # happened before the scenario start.
    psql <<EOF
COPY postgres_log FROM PROGRAM 'sed -ne "/${label}/,$ p" "$PGCSVLOG"' WITH csv;
EOF
    # Import relevant system logs, ignoring whatever happened before the
    # scenario start.
    psql <<EOF
COPY system_log FROM PROGRAM
'sudo sh -c "journalctl -k -o json" | sed -ne ''/${label}/,$ p'' |
  jq -r "[.__REALTIME_TIMESTAMP, .PRIORITY, .MESSAGE] | @csv"'
WITH csv;
EOF
    # FIXME analyze the result and compare:
    # SELECT to_timestamp( realtime_timestamp / 1000000 ), priority, message FROM system_log ;
    # FIXME use "priority >= 4" to get "warn" messages and higher
}

# Create relations used to analyse the test results.
analysis_rels() {

    psql <<EOF
-- Ignore data that cannot be read due to corrutions, so the query does not
-- fail.  That allows us to find what lines are corrupted, because they are
-- referenced from reftable, but missing from the query results.
SET zero_damaged_pages = ON;
-- Extract all events related to this test.
-- Note: If the query sends an error, corrupted data is blocking any action on
-- at least one block.  Reading data while excluding problem blocks will be
-- complicated.  This helps: https://github.com/marco44/postgres_rescue_table
CREATE TABLE events AS
    SELECT *
    FROM (
        -- Get system events.  Priority < 4 gives "emerg"(0), "alert"(1),
        -- "crit"(2), and "err"(3) messages.  Journalctl realtime timestamp is
        -- an epoch timestamp in microseconds, so we can use
        -- "to_timestamp(double)" postgres function if we convert it to seconds
        -- precision.
        SELECT
            to_timestamp( realtime_timestamp / 1000000 ) AS event_time,
            'SYSTEM LOG' AS origin,
            'priority: '||priority::text AS context,
            CASE WHEN priority < 4 THEN 1 ELSE 0 END AS system_error,
            0 AS missing_line,
            '' AS checkpoint_lsn,
            message
        FROM system_log
        UNION ALL
        -- Get PostgreSQL logs regarding checkpoints, regardless of whether it
        -- succeeded or failed.
        SELECT log_time, 'PG LOG - '||error_severity AS origin,
            CASE
                WHEN location LIKE 'LogCheckpointEnd%' THEN 'checkpoint end'
                WHEN location LIKE 'LogCheckpointStart%' THEN 'checkpoint start'
                WHEN location LIKE 'mdsync%' AND error_severity <> 'LOG' THEN 'checkpoint error'
                ELSE ''
            END AS context,
            0 AS system_error,
            0 AS missing_line,
            '' AS checkpoint_lsn,
            message
        FROM postgres_log
        UNION ALL
        -- Get informations regarding checkpoints that occured (and succeeded)
        -- during the test.
        SELECT
            checkpoint_time AS event_time,
            'CHECKPOINT' AS origin,
            '' AS context,
            0 AS system_error,
            0 AS missing_line,
            checkpoint_lsn::text,
            'Checkpoint LSN: '||checkpoint_lsn::text||' - Redo LSN: '||redo_lsn::text AS message
        FROM checkpoint_log
        UNION ALL
        -- Get informations regarding resetwal actions that occured during the
        -- test.
        SELECT
            resetwal_time AS event_time,
            'RESETWAL' AS origin,
            '' AS context,
            0 AS system_error,
            0 AS missing_line,
            resetwal_lsn::text AS checkpoint_lsn,
            'ResetWAL LSN: '||resetwal_lsn::text AS message
        FROM resetwal_log
        UNION ALL
        -- Get lines that are missing due to corruptions.
        SELECT
            insert_time AS event_time,
            'MISSING LINE' AS origin,
            '' AS context,
            0 AS system_error,
            1 AS missing_line,
            '' AS checkpoint_lsn,
            'Insert LSN: '||insert_lsn::text||' - Checkpoint LSN: '||checkpoint_lsn::text AS message
        FROM reftable
        WHERE NOT EXISTS (
            SELECT 1 FROM errtable
            WHERE reftable.refid = errtable.id
        )
    ) base_events
    ORDER BY event_time;
-- Compute statistics for every recorded checkpoint.
CREATE VIEW analysis AS
    SELECT
        next_ok_checkpoints[1],
        min(event_time) FILTER (WHERE origin = 'CHECKPOINT') AS next_checkpoint_time,
        sum(missing_line) AS missing_lines,
        sum(system_error) AS system_errors,
        count(*) FILTER (WHERE context = 'checkpoint error') AS failed_checkpoints,
        count(*) FILTER (WHERE origin = 'PG LOG - PANIC') AS panic_count,
        bool_or(origin = 'RESETWAL') AS resetwal_occured
    FROM (
        SELECT *,
            -- Initialize partitions with succeeded checkpoints LSN over time, so
            -- we can group by on this, and detect which checkpoint "let" passed
            -- errors or corruptions, if any.
            array_agg(checkpoint_lsn)
                FILTER (WHERE checkpoint_lsn <> '')
                OVER (
                    ORDER BY event_time
                    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
                ) AS next_ok_checkpoints
        FROM events
    ) evts
    GROUP BY next_ok_checkpoints[1]
    ORDER BY next_ok_checkpoints[1]::pg_lsn;
-- Show only lines used with corruptions possibly undetected by PostgreSQL.
CREATE VIEW missed_errors AS
    SELECT *
    FROM analysis
    WHERE missing_lines > 0
        AND (failed_checkpoints = 0
            OR panic_count = 0
            OR NOT resetwal_occured);
EOF

}



# FIXME messy
# FIXME incomplete:
# - linux distro, version, and kernel version
# - specifically modified parameters
# - full recap report
compute_reports() {

    # Compute short and detailed text reports.
    mkdir -p "${report_dir}/full_report"
    echo "Scenario played: ${scenario}" >> "${report_dir}/short_report.txt"
    echo "Started at timestamp: ${testtmsp}" >> "${report_dir}/short_report.txt"

    # Extract PostgreSQL running parameters.
    # FIXME these kind of queries would be better dealt with in a
    # collect_<smth> function
    psql <<EOF
COPY (SELECT * FROM pg_settings)
TO '${report_dir}/full_report/pg_settings.dump';
EOF

    # Linux running parameters.
    # shellcheck disable=SC2024
    sudo sysctl -a > "${report_dir}/full_report/sysctl.conf"
    # Extract data from events table, used to do complete analysis.
    psql <<EOF
COPY events
TO '${report_dir}/full_report/events.dump';
EOF
    # Extract dmesg section relevant to the test.
    # shellcheck disable=SC2024
    sudo sh -c "dmesg -T | sed -ne '/${label}/,$ p'" > "${report_dir}/full_report/dmesg.log"
    # Extract PostgreSQL logs section relevant to the test.
    sed -ne "/${label}/,$ p" "$PGLOG" > "${report_dir}/full_report/postgresql.log"
    # Generate short report contents.
    # Missing lines.
    missing_lines=$(psql -Atc "SELECT sum(missing_lines) FROM missed_errors")
    echo "Missing lines due to corruptions: $missing_lines" >> "${report_dir}/short_report.txt"

    # Get audit informations.
    #sudo ausearch -k trace_errtable_file > "${report_dir}/full_report/audit_file.log"
    # shellcheck disable=SC2024
    sudo sh -c 'cat /var/log/audit/*' > "${report_dir}/full_report/audit_file.log"

    # Get kernel debug traces.
    # shellcheck disable=SC2024
    sudo sh -c 'cat /sys/kernel/debug/tracing/trace' > "${report_dir}/full_report/kernel_trace.log"
    # shellcheck disable=SC2024
    sudo sh -c 'cat /sys/kernel/debug/tracing/trace_pipe' > "${report_dir}/full_report/kernel_trace_pipe.log"

    # Remove all audit traces.
    sudo auditctl -D

}








# FIXME source prepare-env-root.sh

# FIXME Setup various test scenario and launch them.
# FIXME reset env if required.



# FIXME why "kernel < 4.13 doomed?"
# https://www.youtube.com/watch?v=1VWIGBQLtxo&feature=youtu.be
# FIXME probably related to fd-checkpointer patch


# FIXME other multiple backends and backend fsync pressure
# Configuration to avoid checkpoints: very high threshold, very low
# shared_buffers.
# pgbench -n -f script.sql





# Scenario 3
# - write intensive FS test
# FIXME is there a difference with Scenario 1? Scenario 2?
# To be used with PGDATA on:
# - sane, local FS, filling local FS to get ENOSPC
# - sane, local FS, changing perms while running to get EPERM
# - NFS, filling remote FS to get ENOSPC
# - NFS, changing perms while running to get EPERM
# - thin provisioned virtual device, filling hypervisor FS to get ENOSPC
# - thin provisioned virtual device, changing perms while running to get EPERM


# FIXME with one tablespace (written to) outside of the affected volume
# FIXME with or without checksum
# FIXME "sync" and "dirty*" with PG 9.5 (or really high *_flush_after?)

# Checks
# - capture errors if any (from PG or the system)
# - verify if there is data corruption


# Configuration tested:
# - PG 11.1
# - PG 11.2
# - PG with fs-checkpointer patch
# - with checksums enabled
# - with high "checkpoint_flush_after" settings
# - with PGDATA on a sane FS, some data written to sane FS, and a tablespace on
#   bad FS


# FIXME add a print_scenario function to dry-run (just print commands)?


#build_install_pg "REL_1_1" "$PG_11_1_ID"
#build_install_pg "REL_1_2" "$PG_11_2_ID"
#build_install_pg "master"  "$PG_patched_ID" "/share/fd-checkpointer.patch"
# FIXME require postgres-manage installed, with configured aliases
# FIXME link to configuration
# FIXME alternative, "self-included" script to build pg?

# Initialize environment variables based on selected version.
#PGWDIR="${HOME}/work/postgresql-${pgversion}"
#export PGDATA="${PGWDIR}/data"
#export PATH="${PGWDIR}/bin:${PATH}"
#export LD_LIBRARY_PATH="${PGWDIR}/lib:${LD_LIBRARY_PATH:-}"
#export PGPORT=5432

# Validate that environment is setup correctly.
if [ -z "$PGDATA" ]; then
    die "PGDATA is not defined."
fi
if ! command -v pg_ctl >/dev/null; then
    die "pg_ctl command not found."
fi
if ! command -v initdb >/dev/null; then
    die "initdb command not found."
fi
if ! command -v psql >/dev/null; then
    die "psql command not found."
fi
# FIXME use must have sudo privileges:
#if ! timeout 1s sudo -v; then
#    etc. die ...
#fi

# Initialize booleans and GUC parameters.
# Parameter to set to apply memory pressure using data insertion on a single
# table.
do_filldata=""
# Parameter to set to apply memory pressure using data insertion on multiple
# tables, and to burn fd using truncates.
do_filltables=""
# Same, but using DELETE instead of TRUNCATE.
do_filltablesdelete=""
# Parameter to set to use a C function to burn many fd.
do_burnfd=""
# Parameter to set to use "dd" to create many files.
do_writemanyfilesduringchkp=""
do_writemanyfilesbeforechkp=""

# Setup logfile names if not defined.
PGLOG=${PGLOG:-${PGDATA}/log/postgresql.log}
PGCSVLOG=${PGCSVLOG:-${PGDATA}/log/postgresql.csv}

# Cleanup existing instance, create new one, start PostgreSQL, do basic
# configuration, create tablespace and relations.
prepare_instance

# Write special line to dmesg to identify scenario starting point.
testtmsp="$(date +'%Y%m%d-%H%M%S-%3N')"
label="fsync test ${testtmsp}"
# FIXME change report dir
report_dir="${HOME}/test_scenario${scenario}_${testtmsp}/reports"
mkdir -p "${report_dir}"
collect_dir="${HOME}/test_scenario${scenario}_${testtmsp}/collect"
mkdir -p "${collect_dir}"
# Write label indicating scenario start into dmesg.
# FIXME running user must be in sudoers without password asked for this to work
sudo sh -c "echo '${label}' > /dev/kmsg"
# Write label indicating scenario start into PostgreSQL logs.
psql <<EOF
SET log_min_duration_statement = 0;
SELECT '${label}';
EOF

# FIXME with the loop device designed to generate errors, the "no-error" zone
# at the beginning of the device ends around 2.5MB.  So ( TEST_COUNT *
# ERROR_LINES_COUNT ) should be setup to more than this, or there will be no
# error to test.

# Number of tests that will be run (including waiting for the next timed
# checkpoint, so every test should be around 10 minutes, but can run up to 30
# minutes if resetwal is required).
TEST_COUNT=3
# Number of lines to be inserted into the error table (due to the table
# attributes definition, 16 lines means one full 8kB data block).
# FIXME 512 lines gives 32 blocks, or 256kB.  With checkpoint_timeout set to
# the minimum (30s), a full test writing 50MB should run into about 100
# minutes.  But this is still a high number of blocks written every time,
# increasing chances checkpoints will capture it... a proper test should be
# done with a much lower line count (the ideal would be the minimum, meaning 16
# or just one 8kB block).
ERROR_LINES_COUNT=16
PREFILL_LINES_COUNT=64

# Scenario section.
# FIXME to be adapted, using a configuration file?
case "$scenario" in
  "1")
    # Scenario 1
    # FIXME very high (relatively) shared buffers to saturate memory during
    # checkpoints
    # delete and insert data into a very high tables number to saturate
    # memory and fd
    psql <<EOF
ALTER SYSTEM SET shared_buffers = '700MB';
--ALTER SYSTEM SET shared_buffers = '256MB';
ALTER SYSTEM SET checkpoint_flush_after = 0;
ALTER SYSTEM SET bgwriter_flush_after = 0;
ALTER SYSTEM SET backend_flush_after = 0;
ALTER SYSTEM SET checkpoint_timeout = '30min';
ALTER SYSTEM SET checkpoint_completion_target = '0.5';
EOF
    # Restart.
    pg_ctl -D "$PGDATA" -m fast -w stop
    pg_ctl -D "$PGDATA" start -l "${PGDATA}/startup.log"
    # Aggressive FS cache cleanup by OS.
    # FIXME running user must be in sudoers without password asked for this to
    # work
    set_aggressive_sysctl
    # FIXME
    do_filltablesdelete="true"
    ;;
  "2")
    # Scenario 2
    # FIXME very high (relatively) shared buffers to saturate memory during
    # checkpoints
    # insert high volume of data data to saturate memory, and burn fd using a
    # custom function
    psql <<EOF
ALTER SYSTEM SET shared_buffers = '700MB';
ALTER SYSTEM SET checkpoint_flush_after = 0;
ALTER SYSTEM SET bgwriter_flush_after = 0;
ALTER SYSTEM SET backend_flush_after = 0;
ALTER SYSTEM SET checkpoint_timeout = '20min';
ALTER SYSTEM SET checkpoint_completion_target = '0.5';
EOF
    # Restart.
    pg_ctl -D "$PGDATA" -m fast -w stop
    pg_ctl -D "$PGDATA" start -l "${PGDATA}/startup.log"
    # Aggressive FS cache cleanup by OS.
    # FIXME running user must be in sudoers without password asked for this to
    # work
    set_aggressive_sysctl
    # FIXME
    do_filldata="true"
    #do_burnfd="true"
    #do_writemanyfilesbeforechkp="true"
    ;;
  "3")
    # Scenario 3
    # FIXME THIS SCENARIO DOES REPRODUCE THE PROBLEM
    # FIXME very high (relatively) shared buffers to saturate memory during
    # checkpoints
    # truncate and insert data into a very high tables number to saturate
    # memory and fd
    psql <<EOF
ALTER SYSTEM SET shared_buffers = '700MB';
--ALTER SYSTEM SET shared_buffers = '256MB';
ALTER SYSTEM SET checkpoint_flush_after = 0;
ALTER SYSTEM SET bgwriter_flush_after = 0;
ALTER SYSTEM SET backend_flush_after = 0;
ALTER SYSTEM SET checkpoint_timeout = '60min';
ALTER SYSTEM SET checkpoint_completion_target = '0.5';
EOF
    # Restart.
    pg_ctl -D "$PGDATA" -m fast -w stop
    pg_ctl -D "$PGDATA" start -l "${PGDATA}/startup.log"
    # Aggressive FS cache cleanup by OS.
    # FIXME running user must be in sudoers without password asked for this to
    # work
    set_aggressive_sysctl
    # FIXME
    do_filltables="true"
    ;;
  "4")
    # Scenario 4
    # Only burn fd
    psql <<EOF
ALTER SYSTEM SET checkpoint_flush_after = 0;
ALTER SYSTEM SET bgwriter_flush_after = 0;
ALTER SYSTEM SET backend_flush_after = 0;
ALTER SYSTEM SET checkpoint_timeout = '5min';
ALTER SYSTEM SET checkpoint_completion_target = '0.9';
EOF
    # Restart.
    pg_ctl -D "$PGDATA" -m fast -w stop
    pg_ctl -D "$PGDATA" start -l "${PGDATA}/startup.log"
    # Aggressive FS cache cleanup by OS.
    # FIXME running user must be in sudoers without password asked for this to
    # work
    set_aggressive_sysctl
    # Burn fd using custom function.
    do_burnfd="true"
    ;;
  "5")
    # Scenario 5
    # Use "dd" to write as many files as possible.
    psql <<EOF
ALTER SYSTEM SET checkpoint_flush_after = 0;
ALTER SYSTEM SET bgwriter_flush_after = 0;
ALTER SYSTEM SET backend_flush_after = 0;
ALTER SYSTEM SET checkpoint_timeout = '30min';
ALTER SYSTEM SET checkpoint_completion_target = '0.5';
EOF
    # Restart.
    pg_ctl -D "$PGDATA" -m fast -w stop
    pg_ctl -D "$PGDATA" start -l "${PGDATA}/startup.log"
    # Aggressive FS cache cleanup by OS.
    # FIXME running user must be in sudoers without password asked for this to
    # work
    set_aggressive_sysctl
    # Burn fd using custom function.
    do_writemanyfilesbeforechkp="true"
    ;;
  "6")
    # Scenario 6
    # FIXME very high (relatively) shared buffers to saturate memory during
    # checkpoints
    # truncate and insert data into a very high tables number to saturate
    # memory and fd
    # FIXME adapt/disable bgwriter:
    #bgwriter_delay, bgwriter_lru_maxpages, bgwriter_lru_multiplier
    psql <<EOF
ALTER SYSTEM SET shared_buffers = '500MB';
--ALTER SYSTEM SET shared_buffers = '128MB';
--ALTER SYSTEM SET shared_buffers = '256MB';
ALTER SYSTEM SET checkpoint_flush_after = 0;
ALTER SYSTEM SET bgwriter_flush_after = 0;
ALTER SYSTEM SET backend_flush_after = 0;
--ALTER SYSTEM SET checkpoint_timeout = '15min';
ALTER SYSTEM SET checkpoint_timeout = '30min';
ALTER SYSTEM SET checkpoint_completion_target = '0.5';
EOF
    # Restart.
    pg_ctl -D "$PGDATA" -m fast -w stop
    pg_ctl -D "$PGDATA" start -l "${PGDATA}/startup.log"
    # Aggressive FS cache cleanup by OS.
    # FIXME running user must be in sudoers without password asked for this to
    # work
    set_aggressive_sysctl
    # FIXME
    do_filltables="true"
    ;;
  "*") echo "Unknown scenario." ; exit 1 ;;
# FIXME other possible scenarios
#  "FIXME")
#    # Scenario FIXME
#    # - checkpoint heavy run test
#    # To be used with pgdata on bad local FS (test EIO)
#    # FIXME also, with NFS mounted and hypervisor bad FS?
#    # Ensure normal FS cache cleanup.
#    set_default_sysctl
#    ;;
#  "FIXME")
#    # Scenario FIXME
#    # - very low shared_buffers
#    # Aggressive FS cache cleanup by OS.
#    # FIXME running user must be in sudoers without password asked for this to
#    # work
#    set_aggressive_sysctl
#    # Configure instance.
#    # FIXME very low shared buffers?
#    psql <<EOF
#ALTER SYSTEM SET shared_buffers = '128kB';
#ALTER SYSTEM SET checkpoint_flush_after = 0;
#ALTER SYSTEM SET bgwriter_flush_after = 0;
#ALTER SYSTEM SET backend_flush_after = 0;
#EOF
#    # Restart.
#    pg_ctl -D "$PGDATA" -m fast -w stop
#    pg_ctl -D "$PGDATA" start -l "${PGDATA}/startup.log"
#    ;;
esac

# FIXME prepare objects to be used in the scenario
if [ -n "$do_filldata" ]; then
    # Get number of lines required to fill the shared buffers with dirty
    # blocks, so we can apply pressure on FS cache during checkpoint.
    # Based on the filltable attribute definition, 16 tuples inserted fill one
    # 8kB block.  So to completely fill shared buffers, we would need to insert
    # ( shared_buffers * 16 ) lines.
    # To be safe and avoid backends having to fsync dirty blocks (and possibly
    # trigger errors we want the checkpointer to get), we work on 90% af shared
    # buffers.
    # FIXME only for saturate_memory scenarios?  bool GUC?
    lines_to_fill=$(psql -At << EOF
SELECT ( setting::int * 0.9 * 16 )::int
FROM pg_settings
WHERE name = 'shared_buffers';
EOF
    )
    prepare_filldata
fi

if [ -n "${do_filltables}${do_filltablesdelete}" ]; then
    # Get number of relations that will be used to fill 90% of the shared
    # buffers with dirty blocks, assuming that every relation will be inserted
    # only on 8kB block of data (16 lines).
    relations_to_fill=$(psql -At << EOF
SELECT ( setting::int * 0.9 )::int
FROM pg_settings
WHERE name = 'shared_buffers';
EOF
    )
    prepare_filltables
fi

if [ -n "$do_burnfd" ]; then
    prepare_burnfd
fi

if [ -n "${do_writemanyfilesduringchkp}${do_writemanyfilesbeforechkp}" ]; then
    tmpfilesdir="tmpfilesdir"
    mkdir -p $tmpfilesdir
    rm "$tmpfilesdir/*" || true
fi

# Lauch test
launch_scenario

# We should get at least one last timed checkpoint here.
# FIXME not true anymore, depends on "checkpoint_timeout" parameter value
sleep 60
# Force two checkpoints to force PostgreSQL to believe data has been synced...
# based on Linux fsync behaviour and unpatched PostgreSQL assomptions, even if
# the first one fails, the second one should succeed.  We do this here because
# if that's the shutdown's checkpoint that fails, PostgreSQL will rightfully
# try to recover using WALs, that will fail because of disk errors, and then
# the instance will not be able to start.
# FIXME only useful to simulate old 11.1 behaviour, when failed fsyncs on
# checkpoint would not automatically PANIC
psql -Atc 'CHECKPOINT' || true
psql -Atc 'CHECKPOINT' || true

# FIXME force restart and drop system caches to see the results
pg_ctl -D "$PGDATA" -m fast -w stop
# FIXME running user must be in sudoers without password asked for this to work
sudo sh -c 'echo 3 > /proc/sys/vm/drop_caches'
# Restart PostgreSQL instance.
pg_ctl -D "$PGDATA" start -l "${PGDATA}/startup.log"

load_events
analysis_rels
compute_reports

# Restore normal FS cache cleanup in case it has been modified.
set_default_sysctl

