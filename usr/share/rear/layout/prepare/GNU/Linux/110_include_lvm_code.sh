# Code to recreate an LVM configuration.
# The input to the code creation functions is a file descriptor to one line
# of the layout description.

if ! has_binary lvm; then
    return
fi

# Test for features in lvm.
# Versions higher than 2.02.73 need --norestorefile if no UUID/restorefile.
FEATURE_LVM_RESTOREFILE=

lvm_version=$(get_version lvm version)

[ "$lvm_version" ]
BugIfError "Function get_version could not detect lvm version."

# RHEL 6.0 contains lvm with knowledge of --norestorefile (issue #462)
if version_newer "$lvm_version" 2.02.71 ; then
    FEATURE_LVM_RESTOREFILE="y"
fi

# Create a new PV.
create_lvmdev() {
    local lvmdev vgrp device uuid junk
    read lvmdev vgrp device uuid junk < <(grep "^lvmdev.*${1#pv:} " "$LAYOUT_FILE")

    (
    echo "LogPrint \"Creating LVM PV $device\""

    ### Work around automatic volume group activation leading to active disks
    echo "lvm vgchange -a n ${vgrp#/dev/} || true"

    local uuidopt=""
    local restorefileopt=""

    if ! is_true "$MIGRATION_MODE" && test -e "$VAR_DIR/layout/lvm/${vgrp#/dev/}.cfg" ; then
        # we have a restore file
        restorefileopt=" --restorefile $VAR_DIR/layout/lvm/${vgrp#/dev/}.cfg"
    else
        if [ -n "$FEATURE_LVM_RESTOREFILE" ] ; then
            restorefileopt=" --norestorefile"
        fi
    fi

    if [ -n "$uuid" ] ; then
        uuidopt=" --uuid \"$uuid\""
    fi
    echo "lvm pvcreate -ff --yes -v$uuidopt$restorefileopt $device >&2"
    ) >> "$LAYOUT_CODE"
}

# Create a new VG.
create_lvmgrp() {
    local lvmgrp vgrp extentsize junk
    read lvmgrp vgrp extentsize junk < <(grep "^lvmgrp $1 " "$LAYOUT_FILE")

    # If we are not migrating, then try using "vgcfgrestore", but this can
    # fail, typically if Thin Pools are used.
    #
    # In such case, we need to rely on vgcreate/lvcreate commands which is not
    # recommended because we are not able to collect all required options yet.
    # For example, we do not take the '--stripes' option into account, nor
    # '--mirrorlog', etc.
    # Also, we likely do not support every layout yet (e.g. 'cachepool').

    if ! is_true "$MIGRATION_MODE" ; then
        cat >> "$LAYOUT_CODE" <<EOF
LogPrint "Restoring LVM VG ${vgrp#/dev/}"
if [ -e "$vgrp" ] ; then
    rm -rf "$vgrp"
fi
if lvm vgcfgrestore -f "$VAR_DIR/layout/lvm/${vgrp#/dev/}.cfg" ${vgrp#/dev/} >&2 ; then
    lvm vgchange --available y ${vgrp#/dev/} >&2

    LogPrint "Sleeping 3 seconds to let udev or systemd-udevd create their devices..."
    sleep 3 >&2
    create_logical_volumes=0
else
    LogPrint "Warning: could not restore LVM configuration using 'vgcfgrestore'. Using traditional 'vgcreate/lvcreate' commands instead ..."
EOF
    fi

    local -a devices=($(grep "^lvmdev $vgrp " "$LAYOUT_FILE" | cut -d " " -f 3))

cat >> "$LAYOUT_CODE" <<EOF
LogPrint "Creating LVM VG ${vgrp#/dev/}"
if [ -e "$vgrp" ] ; then
    rm -rf "$vgrp"
fi
lvm vgcreate --physicalextentsize ${extentsize}k ${vgrp#/dev/} ${devices[@]} >&2
lvm vgchange --available y ${vgrp#/dev/} >&2

create_logical_volumes=1
EOF

    if ! is_true "$MIGRATION_MODE" ; then
        cat >> "$LAYOUT_CODE" <<EOF
fi
EOF
    fi
}

# Create a LV.
create_lvmvol() {
    local name vg lv
    name=${1#/dev/mapper/}
    ### split between vg and lv is single dash
    ### Device mapper doubles dashes in vg and lv
    vg=$(sed "s/\([^-]\)-[^-].*/\1/;s/--/-/g" <<< "$name")
    lv=$(sed "s/.*[^-]-\([^-]\)/\1/;s/--/-/g" <<< "$name")

    # kval: "key:value" pairs, separated by spaces
    local lvmvol vgrp lvname size layout kval
    read lvmvol vgrp lvname size layout kval < <(grep "^lvmvol /dev/$vg $lv " "$LAYOUT_FILE")

    local lvopts=""

    # Handle 'key:value' pairs
    for kv in $kval ; do
        local key=$(awk -F ':' '{ print $1 }' <<< "$kv")
        local value=$(awk -F ':' '{ print $2 }' <<< "$kv")
        lvopts="${lvopts:+$lvopts }--$key $value"
    done

    if [[ ,$layout, == *,thin,* ]] ; then

        if [[ ,$layout, == *,pool,* ]] ; then
            # Thin Pool

            lvopts="${lvopts:+$lvopts }--type thin-pool -L $size"

        else
            # Thin Volume within Thin Pool

            if [[ ,$layout, == *,sparse,* ]] ; then
                lvopts="${lvopts:+$lvopts }-V $size"
            else
                BugError "Unsupported Thin LV layout '$layout' for LV '$lv'"
            fi

        fi

    elif [[ ,$layout, == *,linear,* ]] ; then

        lvopts="${lvopts:+$lvopts }-L $size"

    elif [[ ,$layout, == *,mirror,* ]] ; then

        lvopts="${lvopts:+$lvopts }--type mirror -L $size"

    elif [[ ,$layout, == *,raid,* ]] ; then

        local found=0
        local lvl
        for lvl in raid0 raid1 raid4 raid5 raid6 raid10 ; do
            if [[ ,$layout, == *,$lvl,* ]] ; then
                lvopts="${lvopts:+$lvopts }--type $lvl"
                found=1
                break
            fi
        done

        [ $found -ne 0 ] || BugError "Unsupported LV layout '$layout' found for LV '$lv'"

        lvopts="${lvopts:+$lvopts }-L $size"

    else

        BugError "Unsupported LV layout '$layout' found for LV '$lv'"

    fi

    cat >> "$LAYOUT_CODE" <<EOF
if [ "\$create_logical_volumes" -eq 1 ]; then
    LogPrint "Creating LVM volume ${vgrp#/dev/}/$lvname"
    lvm lvcreate $lvopts -n ${lvname} ${vgrp#/dev/} <<<y
fi
EOF
}

# vim: set et ts=4 sw=4:
