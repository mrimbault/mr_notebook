#------------------------------------------------------------------------------
# Adapted from:
# https://github.com/ringerc/scrapcode/blob/master/testcases/fsync-error-clear/
#------------------------------------------------------------------------------
# Must be sourced.

# Default values.
export FSTYPE="xfs"
# For XFS, disable automatic geometry detection and limit allocation group to
# only one to avoid messing with metadata when using error simulation loop
# devices.
# FIXME only do this for the error FS
export MKFSOPTS=("-d" "agcount=1,noalign" "-f")
export MOUNTOPTS=""
# Units for allocating space, to convert KB and MB values to block number.
export BLOCKS_KB=2
export BLOCKS_MB=$(( 1024 * 2 ))

# Setup a filesystem using a normal device (intended to be a thin provisioned
# virtual disk).
device_fs_setup() {

    # FIXME how to determine the device ID? Can we set it from vagrant/virsh?
    device=$1
    mountpoint=$2

    # Build FS of selected FS type.
    mkfs."$FSTYPE" "${MKFSOPTS[@]}" "$device"

    # Mount it to the specified mount point.
    mkdir -p "$mountpoint"
    if [ -z "$MOUNTOPTS" ]; then
        OPTSSTR=()
    else
        OPTSSTR=("-o" "$MOUNTOPTS")
    fi
    mount "$device" "$mountpoint" "${OPTSSTR[@]}"
}


# FIXME provide size and so as args?
# Create a block device file and mount it as a local FS.
sane_fs_setup() {
    # Get required args.
    blkfile=$1
    mountpoint=$2

    # Convert mountpoint into systemd compatible name (ie "/mnt/my/mnt" give
    # "mnt-my-mnt").
    systemdmnt="$(echo "${mountpoint%/}" | cut -d"/" --output-delimiter="-" -f2-)"

    # Make 100MB file.
    # Total looback dev size to allocate.
    TOTSZ=$(( 100 * BLOCKS_MB ))

    printf "Creating %zu byte block dev\n" \
        $(( TOTSZ * 512 ))

    # Create the block device file.
    dd if=/dev/zero of="$blkfile" bs=512 count=$TOTSZ

    # Build FS of selected FS type.
    mkfs."$FSTYPE" "${MKFSOPTS[@]}" "$blkfile"

    # Create the mount point if necessary.
    mkdir -p "$mountpoint"

    # Add coma at the begining of mount options to concatenate with "loop"
    # option.
    if [ -n "$MOUNTOPTS" ]; then
        MOUNTOPTS=",${MOUNTOPTS}"
    fi

    # Setup automount unit files.
    cat > "/etc/systemd/system/${systemdmnt}.mount" <<EOF
[Unit]
Description=Mount "$blkfile" to "$mountpoint"
[Mount]
What=$blkfile
Where=$mountpoint
Type=$FSTYPE
Options=loop${MOUNTOPTS}
[Install]
WantedBy=multi-user.target
EOF
    cat > "/etc/systemd/system/${systemdmnt}.automount" <<EOF
[Unit]
Description=Automount "$blkfile" to "$mountpoint"
[Automount]
Where=$mountpoint
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable "${systemdmnt}.mount"
    systemctl enable "${systemdmnt}.automount"

    # Mount the filesystem.
    systemctl start "${systemdmnt}.mount"
}

# FIXME provide size and so as args?
# Create a block device file, format FS, and create the table that will be used
# to setup a logical volume with a "bad" section in the middle (blocks that
# always throw errors).  Then create said logical volume, the mount point, and
# mount the filesystem.
# Credit http://serverfault.com/q/498900/102814 for approach.
error_fs_setup() {
    # Get required args.
    blkfile=$1
    device=$2
    mountpoint=$3
    dmtblfile="${HOME}/dm_table_${device}"
    node="/dev/mapper/${device}"

    printf "Creating %zu byte block dev" \
        $(( TOTSZ * 512 ))
    printf "starting with %zu sane bytes" \
        $(( STARTSZ * 512 ))
    printf "and then alterning %zu sane bytes and %zu error bytes.\n" \
        $(( SANESZ * 512 )) \
        $(( ERRSZ * 512 ))

    # Create the block device file.
    dd if=/dev/zero of="$blkfile" bs=512 count=$TOTSZ

    # Build FS of selected FS type.
    mkfs."$FSTYPE" "${MKFSOPTS[@]}" "$blkfile"

    # Create mount point if necessary.
    mkdir -p "$mountpoint"

    # Add mount options as an array to be passed as args.
    if [ -z "$MOUNTOPTS" ]; then
        OPTSSTR=()
    else
        OPTSSTR=("-o" "$MOUNTOPTS")
    fi

    # Setup automount unit file.
    cat > "${HOME}/automount_${device}.sh" <<EOF
#!/bin/bash
# Total looback dev size to allocate.
TOTSZ=$TOTSZ
# Sane blocks size at the begining to avoid errors before testing.
STARTSZ=$STARTSZ
# Bad blocks hole size.
ERRSZ=$ERRSZ
# Alternate with this sane blocks size.
SANESZ=$SANESZ
# Sane blocks size at the middle to avoid errors before testing.
MDLSTARTSZ=$MDLSTARTSZ
MDLSZ=$MDLSZ
# Sane blocks size at the end to avoid errors before testing.
ENDSZ=$ENDSZ
# Get next available noop device.
loopdev="\$(losetup --show -f "$blkfile")"
# Units below are 512B blocks.
# What is done here is preparing a table for dmsetup, so it will:
# - copy the begin of the source device into the created node
# - loop to create alternates of sane blocks and blocks that always cause error
# - create a sane blocks area in the middle to avoid FS mounting problems
# - loop to create alternates of sane blocks and blocks that always cause error
# - copy the end of the source device
cat > "$dmtblfile" <<__END__
0                             \${STARTSZ}               linear \${loopdev} 0
__END__
sizeloop=\$(( STARTSZ ))
while [ "\$(( sizeloop + SANESZ + ERRSZ ))" -lt "\$MDLSTARTSZ" ]; do
    cat >> "$dmtblfile" <<__END__
\${sizeloop}                   \${SANESZ}                linear \${loopdev} \${sizeloop}
\$(( sizeloop + SANESZ ))      \${ERRSZ}                 error
__END__
    (( sizeloop+=( SANESZ + ERRSZ ) ))
done
cat >> "$dmtblfile" <<__END__
\$(( sizeloop ))               \${MDLSZ}  linear \${loopdev} \$(( sizeloop ))
__END__
(( sizeloop+=MDLSZ ))
while [ "\$(( sizeloop + SANESZ + ERRSZ ))" -lt "\$(( TOTSZ - ENDSZ ))" ]; do
    cat >> "$dmtblfile" <<__END__
\${sizeloop}                   \${SANESZ}                linear \${loopdev} \${sizeloop}
\$(( sizeloop + SANESZ ))      \${ERRSZ}                 error
__END__
    (( sizeloop+=( SANESZ + ERRSZ ) ))
done
cat >> "$dmtblfile" <<__END__
\$(( sizeloop ))               \$(( TOTSZ - sizeloop ))  linear \${loopdev} \$(( sizeloop ))
__END__
# Create virtual device defined from table.
dmsetup create "$device" < "$dmtblfile"
dmsetup mknodes "$device"
# Mount the virtual device to the specified mountpoint.
mount "$node" "$mountpoint" ${OPTSSTR[@]}
EOF
    chmod 744 "${HOME}/automount_${device}.sh"
    cat > "/etc/systemd/system/automount_${device}.service" <<EOF
[Unit]
Description=Mount "$device" to "$mountpoint" using "$node"
[Service]
Type=oneshot
ExecStart=${HOME}/automount_${device}.sh
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable "automount_${device}.service"

    # Lauch the script to create the virtual device and mount it.
    systemctl start "automount_${device}.service"

}

low_error_fs_setup() {
    # Total looback dev size to allocate.
    TOTSZ=$(( 100 * BLOCKS_MB ))
    # Sane blocks size at the begining to avoid errors before testing.
    STARTSZ=$(( 512 * BLOCKS_KB ))
    # Bad blocks hole size.
    ERRSZ=$(( 3 * BLOCKS_KB ))
    # Alternate with this sane blocks size.
    SANESZ=$(( 10237 * BLOCKS_KB ))
    # Sane blocks size at the middle to avoid errors before testing.
    MDLSTARTSZ=$(( 48 * BLOCKS_MB ))
    MDLSZ=$(( 8 * BLOCKS_MB ))
    # Sane blocks size at the end to avoid errors before testing.
    ENDSZ=$(( 10 * BLOCKS_MB ))
    # Create FS with specified sizes.
    error_fs_setup "$@"
}

high_error_fs_setup() {
    # Total looback dev size to allocate.
    TOTSZ=$(( 100 * BLOCKS_MB ))
    # Sane blocks size at the begining to avoid errors before testing.
    STARTSZ=$(( 3520 * BLOCKS_KB ))
    # Bad blocks hole size.
    ERRSZ=$(( 3 * BLOCKS_KB ))
    # Alternate with this sane blocks size.
    SANESZ=$(( 29 * BLOCKS_KB ))
    # Sane blocks size at the middle to avoid errors before testing.
    MDLSTARTSZ=$(( 48 * BLOCKS_MB ))
    MDLSZ=$(( 8 * BLOCKS_MB ))
    # Sane blocks size at the end to avoid errors before testing.
    ENDSZ=$(( 512 * BLOCKS_KB ))
    # Create FS with specified sizes.
    error_fs_setup "$@"
}

# Cleanup FS using a loop device.
sane_fs_cleanup() {
    # Get required args.
    blkfile=$1
    mountpoint=$2
    # Convert mountpoint into systemd compatible name (ie "/mnt/my/mnt" give
    # "mnt-my-mnt").
    systemdmnt="$(echo "${mountpoint%/}" | cut -d"/" --output-delimiter="-" -f2-)"
    # Unmount the mountpoint if mounted.
    systemctl stop "${systemdmnt}.mount"
    # Remove block file if exists.
    [ -f "$blkfile" ] && rm -f "$blkfile"
    # Remove automount configuration.
    systemctl disable "${systemdmnt}.mount"
    systemctl disable "${systemdmnt}.automount"
}

# Cleanup FS using a loop device.
error_fs_cleanup() {
    # Get required args.
    blkfile=$1
    device=$2
    mountpoint=$3
    # Unmount the mountpoint if mounted.
    mountpoint -q "$mountpoint" && umount "$mountpoint"
    # Remove loop devices associated to this file if any.
    for lodev in $(losetup -j "$blkfile" | cut -d":" -f1); do
        losetup -d "$lodev"
    done
    # FIXME test existence before removing
    dmsetup remove "$device"
    # Remove block file if exists.
    [ -f "$blkfile" ] && rm -f "$blkfile"
    # Remove automount configuration.
    systemctl disable "automount_${device}.service"
}

# Use to extend a loop device after it has been filled with data.
# FIXME not necessary, just remove files used to fill FS.
extend_blkfile() {

    blkfile=$1
    mountpoint=$2

    # Convert mountpoint into systemd compatible name (ie "/mnt/my/mnt/" give
    # "mnt-my-mnt").
    systemdmnt="$(echo "${mountpoint%/}" | cut -d"/" --output-delimiter="-" -f2-)"

    # Unmount the filesystem.
    systemctl stop "${systemdmnt}.mount"

    # Add 100MB to the loop device file.
    # Size to be added to the looback dev.
    ADDSZ=$(( 100 * BLOCKS_MB ))

    printf "Adding %zu byte block to dev file %s\n" \
        $(( ADDSZ * 512 )) \
        "$blkfile"

    # Add blocks to the block device file.
    dd if=/dev/zero of="$blkfile" bs=512 conv=notrunc oflag=append count=$ADDSZ

    # Get FS type.
    fstype="$(blkid -s TYPE -o value "$blkfile")"

    case "$fstype" in
      "xfs")
        # Remount the filesystem (XFS requires mounted FS).
        systemctl start "${systemdmnt}.mount"
        # Extend it.
        xfs_growfs "$mountpoint"
        ;;
      "ext*")
        # Extend the filesystem.
        resize2fs "$blkfile"
        # Remount it.
        systemctl start "${systemdmnt}.mount"
        ;;
      "*") echo "Unsupported FS for resize: $FSTYPE"; exit 1 ;;
    esac

}

# Fill a FS almost completely with 1MiB files.
fill_fs() {
    mountpoint=$1
    i=0
    # Get free size in kiB.
    freesz="$(( $(stat -f --printf="%a * %s / 1024" "$mountpoint") ))"
    # Set limit to 1MiB.
    limit="1024"
    while [ "$freesz" -gt "$limit" ]; do
        (( i++ ))
        file="fillingfile.${i}"
        fallocate -l "1M" "${mountpoint}/${file}"
        freesz="$(( $(stat -f --printf="%a * %s / 1024" "$mountpoint") ))"
    done
}

# Create directory used to store tablespace data under specified mountpoint.
create_data_dir() {
    mountpoint=$1
    user=$2
    # Check to avoid creating the directory when the filesystem is not mounted.
    if ! mountpoint "$mountpoint"; then
        echo "ERROR: ${mountpoint} is not a mountpoint."
        exit 1
    fi
    install -d -o "$user" -g "$user" -m 700 "${mountpoint}/data"
}



