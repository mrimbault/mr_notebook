#!/bin/bash
# FIXME must be launched as root

# Launch everything:
# shellcheck disable=SC1091
. /share/prepare-env-root.sh
# High error count FS.
error_fs_cleanup "/tmp/errblkfile" "errdevice" "/mnt/error_mount"
high_error_fs_setup "/tmp/errblkfile" "errdevice" "/mnt/error_mount"
create_data_dir "/mnt/error_mount/" "postgres"
# Low error count FS.
error_fs_cleanup "/tmp/lerrblkfile" "lerrdevice" "/mnt/low_error_mount"
low_error_fs_setup "/tmp/lerrblkfile" "lerrdevice" "/mnt/low_error_mount"
create_data_dir "/mnt/low_error_mount/" "postgres"
# Sane FS.
sane_fs_cleanup "/tmp/saneblkfile" "/mnt/sane_mount"
sane_fs_setup "/tmp/saneblkfile" "/mnt/sane_mount"
create_data_dir "/mnt/sane_mount/" "postgres"
mountpoint "/mnt/sane_mount" && fill_fs "/mnt/sane_mount/"


