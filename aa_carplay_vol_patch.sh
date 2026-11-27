#!/bin/ksh
# Android Auto and Apple CarPlay input gain menu backend for the exact
# supported ARM audiomgr.
# The stock executable and an existing startup_main are never modified. The audio table
# gains persist by updating only INPUTGAINOFFSET_GAL/value (AA) and
# INPUTGAINOFFSET_DIO/value (CarPlay) in compiled.dat.
# The numeric string pool is extended without changing other XML settings.

set -u
PATCH_VERSION=1.1
ROOT=${AA_VOLUME_TEST_ROOT:-}
BASE=$ROOT/net/imx6/tsd
SOURCE=$BASE/bin/audioservice/tsd.mibstd2.audio.audiomgr
CONF=$BASE/etc/system/main.conf
STARTUP=$BASE/bin/system/startup_main
STATE=$BASE/var/aa_volume
TARGET=$STATE/tsd.mibstd2.audio.audiomgr.persistent.thin
LEGACY_TARGET=$STATE/tsd.mibstd2.audio.audiomgr
RUNNER=$STATE/start-persistent.sh
LOCK=$BASE/var/.aa_volume.lock
DATA=${0%/*}/aa_volume_data
STOCK_LINE='   command /net/imx6/tsd/bin/audioservice/tsd.mibstd2.audio.audiomgr -control=tsd.audiomgr.control'
LEGACY_LINE='   command /net/imx6/tsd/var/aa_volume/tsd.mibstd2.audio.audiomgr -control=tsd.audiomgr.control'
PATCH_LINE='   command /bin/ksh /net/imx6/tsd/var/aa_volume/start-persistent.sh -control=tsd.audiomgr.control'
CONF_STAGE=$CONF.aa-volume-new
TABLE=$BASE/var/audio/audiotable/compiled.dat
TABLE_STAGE=$TABLE.aa-volume-new
RUNTIME_STAGE=$TABLE.aa-gain-new
RUNTIME_LOCK=$TABLE.aa-gain-lock
OWN_RUNTIME=
ROOT_RW=
LOCKED=
STAGED=
TABLE_ROLLBACK=

# Layout-specific values, chosen by select_layout:
# P0478T: the unit's older i.MX6 hook; startup_main loads
#   /net/imx6/tsd/etc/system/main.conf on the read-only root filesystem.
# P0480T-Toolbox-CP: the MIBSTD2 Toolbox CP patch hook; startup_main loads
#   /tsd/var/main.conf and J5 runs the CP-patched audiomgr from /tsd/var.
# P0480T-J5: no CP patch; J5 runs its built-in /tsd/bin/audio audiomgr. Either
#   another mod's /tsd/var hook exists, or this installer creates the same kind
#   of hook (startup_main plus a verified copy of the J5 main.conf in /tsd/var)
#   and removes it again on rollback when nothing else changed that config.
# Each layout has fingerprints and a delta for its local audiomgr.
LAYOUT=P0478T
BIN=$DATA
CONF_BACKUP=main.conf.before
STARTUP_ARG='-file=/net/imx6/tsd/etc/system/main.conf '
REMOUNT_ROOT=1
REQUIRE_J5_KSH=
OWN_HOOK=
CREATE_HOOK=
STALE_CONF=
J5_AUDIOMGR=$ROOT/net/J5/tsd/bin/audio/tsd.mibstd2.audio.audiomgr
J5_CONF=$ROOT/net/J5/tsd/etc/system/main.conf
VAR_CONF=$BASE/var/main.conf
J5_LINE='   command /tsd/bin/audio/tsd.mibstd2.audio.audiomgr -control=tsd.audiomgr.control'
J5_PATCH_LINE='   command /bin/ksh /net/imx6/tsd/var/aa_volume/start-p480.sh -control=tsd.audiomgr.control'
J5_PATCH_LINE_US='   command /bin/ksh /net/imx6/tsd/var/aa_volume/start-pus.sh -control=tsd.audiomgr.control'

# Exactly one occurrence of LINE in FILE (missing file: none).
line_in() (
    [ -f "$1" ] || return 1
    matches=0
    while IFS= read -r config_line || [ -n "$config_line" ]; do
        [ "$config_line" != "$2" ] || matches=$((matches + 1))
    done < "$1"
    [ "$matches" -eq 1 ]
)

select_layout() {
    if [ -f "$STARTUP" ]; then
        grep -F -q -e '-file=/tsd/var/main.conf ' "$STARTUP" || return 0
        if ! line_in "$VAR_CONF" "$J5_LINE" && ! line_in "$VAR_CONF" "$J5_PATCH_LINE" \
            && ! line_in "$VAR_CONF" "$J5_PATCH_LINE_US"; then
            select_toolbox
            return 0
        fi
    else
        # Without any hook J5 boots its built-in configuration.
        [ -f "$J5_AUDIOMGR" ] || return 0
        CREATE_HOOK=1
    fi
    LAYOUT=P0480T-J5
    SOURCE=$J5_AUDIOMGR
    BIN=$DATA/p480
    TARGET=$STATE/tsd.mibstd2.audio.audiomgr.p480.thin
    RUNNER=$STATE/start-p480.sh
    CONF_BACKUP=main.conf.p480.before
    STOCK_LINE=$J5_LINE
    PATCH_LINE=$J5_PATCH_LINE
    OWN_HOOK=1
    # Same layout on the US NAR firmware: another audiomgr build (handler code
    # 0x620 lower). Chosen only when J5 runs exactly that build.
    if ! matches_image "$BIN/stock" "$SOURCE" && matches_image "$DATA/pus/stock" "$SOURCE"; then
        LAYOUT=US-NAR-J5
        BIN=$DATA/pus
        TARGET=$STATE/tsd.mibstd2.audio.audiomgr.pus.thin
        RUNNER=$STATE/start-pus.sh
        CONF_BACKUP=main.conf.pus.before
        PATCH_LINE=$J5_PATCH_LINE_US
    fi
    select_var_conf
    # Without startup_main, /tsd/var/main.conf is not loaded. A leftover copy
    # (for example after a firmware update removed the hook) is inactive: it is
    # ignored, kept on Restore, and moved into the AA state directory on Install.
    if [ -n "$CREATE_HOOK" ] && { [ -e "$CONF" ] || [ -L "$CONF" ]; } \
        && ! matches "$CONF" "$DATA/j5_conf.check"; then
        STALE_CONF=1
    fi
}

select_toolbox() {
    LAYOUT=P0480T-Toolbox-CP
    SOURCE=$BASE/var/tsd.mibstd2.audio.audiomgr
    BIN=$DATA/tb480
    TARGET=$STATE/tsd.mibstd2.audio.audiomgr.tb480.thin
    RUNNER=$STATE/start-tb480.sh
    CONF_BACKUP=main.conf.tb480.before
    STOCK_LINE='   command /tsd/var/tsd.mibstd2.audio.audiomgr -control=tsd.audiomgr.control'
    PATCH_LINE='   command /bin/ksh /net/imx6/tsd/var/aa_volume/start-tb480.sh -control=tsd.audiomgr.control'
    if ! matches_image "$BIN/stock" "$SOURCE" && matches_image "$DATA/tbus/stock" "$SOURCE"; then
        LAYOUT=US-NAR-Toolbox-CP
        BIN=$DATA/tbus
        TARGET=$STATE/tsd.mibstd2.audio.audiomgr.tbus.thin
        RUNNER=$STATE/start-tbus.sh
        CONF_BACKUP=main.conf.tbus.before
        PATCH_LINE='   command /bin/ksh /net/imx6/tsd/var/aa_volume/start-tbus.sh -control=tsd.audiomgr.control'
    fi
    select_var_conf
}

select_var_conf() {
    CONF=$VAR_CONF
    CONF_STAGE=$CONF.aa-volume-new
    STARTUP_ARG='-file=/tsd/var/main.conf '
    REMOUNT_ROOT=
    REQUIRE_J5_KSH=1
    # The direct-exec legacy release never existed for these layouts. A value
    # containing a newline never equals a line returned by read, so the
    # legacy branches cannot match here.
    LEGACY_LINE='
'
    LEGACY_TARGET=$STATE/.aa-volume-no-legacy-backend
}

die() { echo "ERROR: $*"; exit 1; }
same() { cmp "$1" "$2" >/dev/null 2>&1; }

# Use ksh builtins for text/hex handling. On the supported radio awk crashes
# in SignalAction and tr is unavailable. Keep helper variables in subshells.
# QNX ksh also lacks printf. Its print builtin supports raw output and an
# optional suppressed newline without calling an external utility.
has_line() (
    [ -z "$STALE_CONF" ] && [ -f "$CONF" ] || return 1
    expected_line=$1
    matches=0
    while IFS= read -r config_line || [ -n "$config_line" ]; do
        if [ "$config_line" = "$expected_line" ]; then
            matches=$((matches + 1))
        fi
    done < "$CONF"
    [ "$matches" -eq 1 ]
)

file_size() (
    listing=$(ls -ln "$1") || return 1
    set -f
    set -- $listing
    [ "$#" -ge 5 ] || return 1
    case $5 in ''|*[!0-9]*) return 1 ;; esac
    print -r -- "$5"
)

hex_piece() (
    dump=$(od -An -v -tx1 -j "$2" -N "$3" "$1") || return 1
    expected_length=$(($3 * 2))
    set -f
    set -- $dump
    hex=
    for byte do
        case $byte in [0-9a-f][0-9a-f]) hex=$hex$byte ;; *) return 1 ;; esac
    done
    [ "${#hex}" -eq "$expected_length" ] || return 1
    print -r -- "$hex"
)

rewrite_config() (
    old_line=$1
    new_line=$2
    replacements=0
    while :; do
        config_line=
        IFS= read -r config_line
        line_status=$?
        [ "$line_status" -eq 0 ] || [ -n "$config_line" ] || break
        if [ "$config_line" = "$old_line" ]; then
            config_line=$new_line
            replacements=$((replacements + 1))
        fi
        if [ "$line_status" -eq 0 ]; then
            print -r -- "$config_line" || return 1
        else
            print -rn -- "$config_line" || return 1
            break
        fi
    done < "$CONF"
    [ "$replacements" -eq 1 ]
)

cleanup() {
    if [ -n "$TABLE_ROLLBACK" ] && ! has_line "$PATCH_LINE"; then
        if cp -p "$STATE/transaction.table.before" "$TABLE_STAGE" \
            && same "$STATE/transaction.table.before" "$TABLE_STAGE" \
            && mv -f "$TABLE_STAGE" "$TABLE"; then
            sync
            echo "Previous audio table restored after incomplete installation."
        else
            echo "ERROR: restoring the original audio table failed: $STATE/table.before"
        fi
    fi
    if [ -n "$ROOT_RW" ]; then
        mount -t qnx6 -o remount,ro /dev/hd0t177 / \
            || echo "ERROR: could not restore root filesystem read-only; do not reboot yet"
    fi
    if [ -n "$STAGED" ]; then
        rm -f "$STATE/backend.new" "$STATE/main.conf.new" "$STATE/backup.new" "$STATE/payload.original" "$STATE/table.original" "$STATE/table.backup.new" "$STATE/runner.new" "$STATE/transaction.table.before" "$CONF_STAGE" "$TABLE_STAGE" "$STARTUP.aa-volume-new"
    fi
    if [ -n "$OWN_RUNTIME" ]; then
        rm -f "$RUNTIME_LOCK"
    fi
    if [ -n "$LOCKED" ]; then
        rmdir "$LOCK" 2>/dev/null
    fi
}

preflight() {
    [ -f "$BIN/stock.check" ] && [ -f "$BIN/backend.check" ] && [ -f "$DATA/table/stock.check" ] \
        || die "aa_volume_data payload is missing"
    command -v sha256sum >/dev/null 2>&1 || command -v gzip >/dev/null 2>&1 \
        || die "no supported file fingerprint utility (sha256sum or gzip)"
    if [ "$ACTION" = install ]; then
        matches "$BIN/start.sh" "$BIN/start.check" || die "AA startup runner fingerprint mismatch"
    fi
    if [ -z "$CREATE_HOOK" ]; then
        [ -f "$STARTUP" ] || die "startup_main is missing and J5 is not reachable"
        grep -F -q -e "$STARTUP_ARG" "$STARTUP" \
            || die "startup_main loads another configuration; no changes made"
    fi
    # Only selecting the runner needs J5's shell; status and Restore must not.
    if [ -n "$REQUIRE_J5_KSH" ] && [ "$ACTION" = install ]; then
        [ -f "$ROOT/net/J5/bin/ksh" ] || die "J5 /bin/ksh not found; the AA startup runner cannot start on J5"
    fi
    [ -f "$SOURCE" ] && [ ! -L "$SOURCE" ] || die "stock ARM audiomgr is missing or is a symlink"
    matches_image "$BIN/stock" "$SOURCE" || die "unsupported or modified audiomgr; no changes made"
    if [ -n "$OWN_HOOK" ]; then
        [ -f "$DATA/j5_conf.check" ] && [ -f "$DATA/j5_hook.sh" ] || die "J5 hook payload is missing"
    fi
    if [ -n "$CREATE_HOOK" ]; then
        matches "$DATA/j5_hook.sh" "$DATA/j5_hook.check" || die "J5 startup hook fingerprint mismatch"
        # J5 boots its built-in main.conf. The hook copy must be that file.
        [ ! -L "$J5_CONF" ] && matches "$J5_CONF" "$DATA/j5_conf.check" \
            || die "unsupported J5 main.conf; no changes made"
        [ ! -e "$STARTUP.aa-volume-new" ] && [ ! -L "$STARTUP.aa-volume-new" ] \
            || die "stale startup_main staging file; no changes made"
        if [ -e "$CONF" ] || [ -L "$CONF" ]; then
            [ -f "$CONF" ] && [ ! -L "$CONF" ] || die "inactive $CONF is not a regular file; no changes made"
        fi
    else
        [ -f "$CONF" ] && [ ! -L "$CONF" ] || die "main.conf is missing or is a symlink"
    fi
    [ ! -L "$STATE" ] || die "AA state directory is a symlink"
    [ ! -e "$CONF_STAGE" ] && [ ! -L "$CONF_STAGE" ] || die "stale config staging file; no changes made"
    [ -f "$TABLE" ] && [ ! -L "$TABLE" ] || die "compiled audio table is missing or is a symlink"
    [ ! -e "${TABLE%/*}/audiotable.xml" ] && [ ! -L "${TABLE%/*}/audiotable.xml" ] \
        || die "custom audiotable.xml exists; no changes made"
    [ ! -e "$TABLE_STAGE" ] && [ ! -L "$TABLE_STAGE" ] || die "stale audio table staging file; no changes made"
    if ! matches "$TABLE" "$DATA/table/stock.check" && ! matches "$TABLE" "$DATA/table/legacy.check" && ! runtime_table "$TABLE"; then
        die "unsupported or modified audio table; no changes made"
    fi
    [ -z "$STALE_CONF" ] && [ -f "$CONF" ] || return 0
    startup_count=0
    while IFS= read -r config_line || [ -n "$config_line" ]; do
        case $config_line in
            "$STOCK_LINE"|"$PATCH_LINE"|"$LEGACY_LINE") startup_count=$((startup_count + 1)) ;;
        esac
    done < "$CONF"
    [ "$startup_count" -eq 1 ] || die "missing or multiple audio startup commands; no changes made"
    if has_line "$STOCK_LINE"; then
        ! has_line "$PATCH_LINE" || die "multiple audio startup commands; no changes made"
    elif has_line "$LEGACY_LINE"; then
        matches_image "$DATA/legacy" "$LEGACY_TARGET" || die "legacy AA backend differs from reference"
    elif ! has_line "$PATCH_LINE"; then
        die "audio startup command differs from the supported configuration; no changes made"
    fi
}

operation_lock() {
    mkdir "$LOCK" 2>/dev/null || die "another AA operation is running, or state directory is not writable"
    LOCKED=1
    trap cleanup 0
    trap 'exit 1' HUP INT TERM
}

lock() {
    operation_lock
    (set -C; : > "$RUNTIME_LOCK") 2>/dev/null || die "AA save is active or its lock survived interruption; reboot before retry"
    OWN_RUNTIME=1
    [ ! -e "$RUNTIME_STAGE" ] && [ ! -L "$RUNTIME_STAGE" ] || die "AA staging survived interruption; reboot before retry"
    preflight
}

# Compare the patched instructions and reconstruct all original bytes from the
# payload plus the stock executable. This catches SD/payload corruption without
# requiring Python, a hash utility, or an ARM toolchain on the radio.
piece() {
    if [ "$3" -gt 0 ]; then
        tail -c +$(($2 + 1)) "$1" | head -c "$3"
    fi
}

# Prefer SHA-256 where available. The extracted QNX ships gzip; its last
# eight bytes give the CRC32 and uncompressed size of the complete stream.
verify_stream() (
    if command -v sha256sum >/dev/null 2>&1; then
        hash=$(sha256sum) || return 1
        [ "${hash%% *}" = "$2" ]
    else
        bytes=$(gzip -1 -c | tail -c 8 | od -An -v -tx1) || return 1
        set -f
        set -- "$1" $bytes
        [ "$#" -eq 9 ] || return 1
        [ "$2$3$4$5$6$7$8$9" = "$1" ]
    fi
)

matches() (
    [ -f "$1" ] && [ -f "$2" ] || return 1
    read crc sha < "$2" || return 1
    verify_stream "$crc" "$sha" < "$1"
)

matches_image() { matches "$2" "$1.check"; }

own_startup() {
    same "$STARTUP" "$DATA/j5_hook.sh" || matches "$STARTUP" "$DATA/old_j5_hook.check"
}

# Stream an exact delta against a local original. Every run includes the
# original bytes at that offset. The caller verifies the finished file.
emit_delta() (
    source=$1
    delta=$2
    size=$(file_size "$source") || return 1
    cursor=0
    used=0
    while read offset length expected; do
        [ "$offset" -ge "$cursor" ] && [ "$length" -gt 0 ] && [ $((offset + length)) -le "$size" ] || return 1
        actual=$(hex_piece "$source" "$offset" "$length") || return 1
        [ "$actual" = "$expected" ] || return 1
        piece "$source" "$cursor" "$((offset - cursor))" || return 1
        piece "$delta.bytes" "$used" "$length" || return 1
        cursor=$((offset + length))
        used=$((used + length))
    done < "$delta.regions" || return 1
    [ "$(file_size "$delta.bytes")" = "$used" ] || return 1
    piece "$source" "$cursor" "$((size - cursor))" || return 1
    cat "$delta.tail"
)

runtime_table() {
    [ -f "$DATA/table/values.txt" ] || return 1
    read voff vsize coff < "$DATA/table/values.txt" || return 1
    [ "$coff" -ge $((voff + 4)) ] && [ "$vsize" -ge $((coff + 4)) ] || return 1
    [ "$(file_size "$1")" = "$vsize" ] || return 1
    actual=$(hex_piece "$1" "$voff" 4) || return 1
    actual_carplay=$(hex_piece "$1" "$coff" 4) || return 1
    saved=
    saved_carplay=
    value=-14
    while IFS= read -r pointer; do
        if [ "$value" -ge -13 ]; then
            [ "$pointer" != "$actual" ] || [ -n "$saved" ] || saved=$value
            [ "$pointer" != "$actual_carplay" ] || [ -n "$saved_carplay" ] || saved_carplay=$value
        fi
        value=$((value + 1))
    done < "$DATA/table/values.txt"
    [ -n "$saved" ] && [ -n "$saved_carplay" ] || return 1
    read crc sha < "$DATA/table/normalized.check" || return 1
    {
        piece "$1" 0 "$voff"
        cat "$DATA/table/zero.bin"
        piece "$1" "$((voff + 4))" "$((coff - voff - 4))"
        cat "$DATA/table/zero.bin"
        piece "$1" "$((coff + 4))" "$((vsize - coff - 4))"
    } | verify_stream "$crc" "$sha"
}

verify_payload() {
    matches_image "$BIN/stock" "$SOURCE" || die "original backend fingerprint changed"
    emit_delta "$SOURCE" "$BIN/backend" > "$STATE/backend.new" || die "cannot apply AA backend delta"
    matches_image "$BIN/backend" "$STATE/backend.new" || die "AA backend fingerprint mismatch"
}

prepare_state() {
    mkdir -p "$STATE" || die "cannot create AA state directory"
    for name in backend.new main.conf.new backup.new payload.original table.original table.backup.new runner.new transaction.table.before; do
        [ ! -e "$STATE/$name" ] && [ ! -L "$STATE/$name" ] \
            || die "stale state staging file $name; no changes made"
    done
    STAGED=1
}

write_table() {
    cp -p "$TABLE" "$TABLE_STAGE" \
        && cat "$1" > "$TABLE_STAGE" \
        && same "$1" "$TABLE_STAGE" \
        && mv -f "$TABLE_STAGE" "$TABLE" || die "cannot replace audio table"
    sync
}

switch_config() {
    from=$1
    to=$2
    rewrite_config "$from" "$to" > "$STATE/main.conf.new" || die "cannot prepare audio startup command"
    if [ -n "$REMOUNT_ROOT" ]; then
        mount -t qnx6 -o remount,rw /dev/hd0t177 / || die "cannot remount root filesystem read-write"
        ROOT_RW=1
    fi
    cp -p "$CONF" "$CONF_STAGE" \
        && cat "$STATE/main.conf.new" > "$CONF_STAGE" \
        && same "$STATE/main.conf.new" "$CONF_STAGE" \
        && mv -f "$CONF_STAGE" "$CONF" || die "cannot replace main.conf; inspect backend status before reboot"
    sync
    if [ -n "$REMOUNT_ROOT" ]; then
        mount -t qnx6 -o remount,ro /dev/hd0t177 / || die "cannot remount root filesystem read-only"
        ROOT_RW=
    fi
    has_line "$to" || die "audio startup command verification failed"
}

# P0480T without a hook: create the same hook the Toolbox and SWA mods use.
# The /tsd/var/main.conf copy is the verified J5 main.conf, so the hook alone
# boots J5 exactly like its built-in configuration. startup_main comes last.
create_hook() {
    if [ -n "$STALE_CONF" ]; then
        inactive=$STATE/main.conf.inactive.before
        if [ -e "$inactive" ] || [ -L "$inactive" ]; then
            same "$CONF" "$inactive" || die "$inactive already holds another inactive main.conf; inspect it, no changes made"
            rm -f "$CONF" || die "cannot remove inactive $CONF"
        else
            mv "$CONF" "$inactive" || die "cannot move inactive $CONF"
        fi
        sync
        echo "Inactive $CONF moved to $inactive."
        STALE_CONF=
    fi
    if [ ! -e "$CONF" ]; then
        cp "$J5_CONF" "$CONF_STAGE" \
            && matches "$CONF_STAGE" "$DATA/j5_conf.check" \
            && mv "$CONF_STAGE" "$CONF" || die "cannot create $CONF"
        sync
    fi
    if [ ! -e "$STARTUP" ]; then
        mount -t qnx6 -o remount,rw /dev/hd0t177 / || die "cannot remount root filesystem read-write"
        ROOT_RW=1
        cp "$DATA/j5_hook.sh" "$STARTUP.aa-volume-new" \
            && matches "$STARTUP.aa-volume-new" "$DATA/j5_hook.check" \
            && chmod 755 "$STARTUP.aa-volume-new" \
            && mv "$STARTUP.aa-volume-new" "$STARTUP" || die "cannot create startup_main"
        sync
        mount -t qnx6 -o remount,ro /dev/hd0t177 / || die "cannot remount root filesystem read-only"
        ROOT_RW=
        [ -x "$STARTUP" ] || die "startup_main is not executable"
        echo "J5 startup hook created: $STARTUP loads $CONF."
    fi
    CREATE_HOOK=
}

# Remove only an unchanged hook that this installer created. If another mod
# (for example SWA) changed /tsd/var/main.conf, the hook stays for that mod.
remove_hook() {
    [ -n "$OWN_HOOK" ] || return 0
    if [ -n "$STALE_CONF" ]; then
        echo "Inactive $CONF (no startup_main) left unchanged."
        return 0
    fi
    if [ -f "$STARTUP" ] && ! own_startup; then
        echo "J5 startup hook belongs to another mod; kept."
        return 0
    fi
    if [ -f "$CONF" ] && ! matches "$CONF" "$DATA/j5_conf.check"; then
        [ -f "$STARTUP" ] && echo "J5 startup hook kept: $CONF has other changes."
        return 0
    fi
    if [ -f "$STARTUP" ]; then
        mount -t qnx6 -o remount,rw /dev/hd0t177 / || die "cannot remount root filesystem read-write"
        ROOT_RW=1
        rm -f "$STARTUP" || die "cannot remove startup_main"
        sync
        mount -t qnx6 -o remount,ro /dev/hd0t177 / || die "cannot remount root filesystem read-only"
        ROOT_RW=
    fi
    rm -f "$CONF" || die "cannot remove $CONF"
    sync
    echo "J5 startup hook removed; J5 uses its built-in configuration after restart."
}

# Earlier releases of this layout: BIN/previous_backends.txt lists
# "<file in the AA state directory> <fingerprint in BIN>", previous_runners.txt
# the runner fingerprints. A previous backend is never overwritten; the new one uses
# a new path and the runner switches to it.
previous_backend() {
    [ -f "$BIN/previous_backends.txt" ] || return 1
    while read prev image; do
        [ -n "$prev" ] && [ -n "$image" ] || continue
        if [ -f "$STATE/$prev" ] && [ ! -L "$STATE/$prev" ] && matches_image "$BIN/$image" "$STATE/$prev"; then
            return 0
        fi
    done < "$BIN/previous_backends.txt"
    return 1
}

previous_runner() {
    [ -f "$BIN/previous_runners.txt" ] || return 1
    [ -f "$RUNNER" ] && [ ! -L "$RUNNER" ] || return 1
    while read crc sha; do
        [ -n "$crc" ] && [ -n "$sha" ] || continue
        verify_stream "$crc" "$sha" < "$RUNNER" && return 0
    done < "$BIN/previous_runners.txt"
    return 1
}

check_installed() {
    [ ! -L "$TARGET" ] && [ ! -L "$RUNNER" ] || die "AA executable or runner is a symlink"
    upgrade_backend=
    if [ -e "$TARGET" ]; then
        matches_image "$BIN/backend" "$TARGET" || die "configured AA backend differs from payload; no changes made"
    else
        previous_backend || die "configured AA backend differs from supported versions; no changes made"
        upgrade_backend=1
    fi
    runtime_table "$TABLE" || die "AA backend selected but persistent table is missing"
    upgrade_runner=
    if ! same "$RUNNER" "$BIN/start.sh"; then
        previous_runner || die "AA startup runner differs from supported versions"
        upgrade_runner=1
    fi
    if [ -n "$upgrade_backend$upgrade_runner" ]; then
        # Only replace the known old script inode. Do not reserve or release the
        # backend's runtime lock here: an already running old startup script
        # could otherwise clear that lock. Table/config/executable stay intact.
        # The fsync fix uses a new executable path; an active previous backend
        # is preserved. Copy/verify the new file before switching the runner.
        prepare_state
        if [ -n "$upgrade_backend" ]; then
            verify_payload
            chmod 755 "$STATE/backend.new" \
                && mv "$STATE/backend.new" "$TARGET" || die "cannot stage the new AA backend"
            sync
        fi
    fi
    if [ -n "$upgrade_runner" ]; then
        cp "$BIN/start.sh" "$STATE/runner.new" \
            && same "$BIN/start.sh" "$STATE/runner.new" \
            && chmod 755 "$STATE/runner.new" \
            && mv -f "$STATE/runner.new" "$RUNNER" || die "cannot upgrade startup runner"
        sync
        echo "AA startup runner updated. Saved AA and CarPlay gains preserved."
    fi
    if [ -n "$upgrade_backend" ]; then
        echo "New AA/CarPlay backend staged at a new path. Running previous executable preserved; reboot to activate."
    fi
    echo "AA backend already selected for startup. Restart the unit if not done yet."
}

install() {
    preflight
    if has_line "$PATCH_LINE"; then
        operation_lock
        preflight
        has_line "$PATCH_LINE" || die "startup selection changed; retry installation"
        check_installed
        return
    fi
    lock
    if has_line "$PATCH_LINE"; then
        check_installed
        return
    fi
    from="$STOCK_LINE"
    has_line "$LEGACY_LINE" && from="$LEGACY_LINE"
    if [ -e "$TARGET" ] || [ -L "$TARGET" ]; then
        [ ! -L "$TARGET" ] && matches_image "$BIN/backend" "$TARGET" \
            || die "another file occupies the AA backend path; no changes made"
    fi
    [ ! -e "$RUNNER" ] || same "$RUNNER" "$BIN/start.sh" || die "another file occupies startup runner"
    [ ! -L "$RUNNER" ] || die "startup runner is a symlink"
    prepare_state
    verify_payload
    if ! runtime_table "$TABLE"; then
        stock_table=$TABLE
        if ! matches "$stock_table" "$DATA/table/stock.check"; then
            stock_table=$STATE/table.before
        fi
        [ ! -L "$stock_table" ] && matches "$stock_table" "$DATA/table/stock.check" \
            || die "original audio table reference is missing or invalid"
        emit_delta "$stock_table" "$DATA/table/persistent" > "$STATE/table.original" \
            || die "cannot prepare persistent audio table"
        matches "$STATE/table.original" "$DATA/table/persistent.check" || die "audio table fingerprint mismatch"
    fi
    [ ! -L "$STATE/table.before" ] || die "audio table backup path is a symlink"
    if [ -e "$STATE/table.before" ]; then
        matches "$STATE/table.before" "$DATA/table/stock.check" || die "original audio table backup differs from reference"
    else
        matches "$TABLE" "$DATA/table/stock.check" || die "persistent table exists without an original backup"
    fi
    [ -z "$CREATE_HOOK" ] || create_hook
    [ ! -L "$STATE/$CONF_BACKUP" ] || die "backup path is a symlink"
    if [ ! -e "$STATE/$CONF_BACKUP" ]; then
        cp -p "$CONF" "$STATE/backup.new" \
            && same "$CONF" "$STATE/backup.new" \
            && mv "$STATE/backup.new" "$STATE/$CONF_BACKUP" || die "cannot back up main.conf"
    fi
    if [ ! -e "$TARGET" ]; then
        chmod 755 "$STATE/backend.new" \
            && mv "$STATE/backend.new" "$TARGET" || die "cannot stage AA backend"
    fi
    if [ ! -e "$RUNNER" ]; then
        cp "$BIN/start.sh" "$STATE/runner.new" \
            && same "$BIN/start.sh" "$STATE/runner.new" \
            && chmod 755 "$STATE/runner.new" \
            && mv "$STATE/runner.new" "$RUNNER" || die "cannot install startup runner"
    fi
    [ -x "$TARGET" ] || die "AA backend is not executable"
    sync
    if [ ! -e "$STATE/table.before" ]; then
        cp -p "$TABLE" "$STATE/table.backup.new" \
            && matches "$STATE/table.backup.new" "$DATA/table/stock.check" \
            && mv "$STATE/table.backup.new" "$STATE/table.before" || die "cannot back up audio table"
    fi
    if [ -f "$STATE/table.original" ]; then
        cp -p "$TABLE" "$STATE/transaction.table.before" || die "cannot stage previous table"
        TABLE_ROLLBACK=1
        write_table "$STATE/table.original"
    fi
    switch_config "$from" "$PATCH_LINE"
    TABLE_ROLLBACK=
    echo "AA backend selected for startup. Original executable preserved."
    echo "Restart the unit, then open MIBSTD2 Toolbox > aa_carplay_vol_patch."
    echo "Sliders save INPUTGAINOFFSET_GAL (AA) and INPUTGAINOFFSET_DIO (CarPlay) atomically."
    echo "Native boot loads the saved table."
}

uninstall() {
    preflight
    lock
    if has_line "$STOCK_LINE" || [ ! -f "$CONF" ] || [ -n "$STALE_CONF" ]; then
        if matches "$TABLE" "$DATA/table/stock.check"; then
            remove_hook
            echo "Original backend and audio table already selected."
            return
        fi
    fi
    [ -d "$STATE" ] || die "AA state directory is missing"
    prepare_state
    [ -f "$STATE/table.before" ] && matches "$STATE/table.before" "$DATA/table/stock.check" \
        || die "original audio table backup is missing or differs from reference"
    if has_line "$PATCH_LINE"; then
        switch_config "$PATCH_LINE" "$STOCK_LINE"
    elif has_line "$LEGACY_LINE"; then
        switch_config "$LEGACY_LINE" "$STOCK_LINE"
    fi
    if ! matches "$TABLE" "$DATA/table/stock.check"; then
        write_table "$STATE/table.before"
    fi
    remove_hook
    echo "Original backend and audio table restored. Restart the unit."
    echo "AA files and the first configuration backup remain available for inspection."
}

status() {
    preflight
    if has_line "$PATCH_LINE"; then
        if matches_image "$BIN/backend" "$TARGET" && same "$RUNNER" "$BIN/start.sh"; then
            echo "AA backend selected for startup; payload matches."
        elif previous_backend && previous_runner; then
            echo "Previous persistent backend selected. Install AA backend, then reboot to activate the CarPlay slider."
        else
            die "AA backend or startup runner differs from supported versions"
        fi
    elif has_line "$LEGACY_LINE"; then
        echo "Legacy AA backend selected; install this version to enable persistence."
    else
        echo "Original backend selected for startup."
    fi
    if [ -n "$OWN_HOOK" ]; then
        if [ ! -f "$STARTUP" ]; then
            echo "J5 startup hook: none (J5 built-in configuration; Install creates it)."
            [ -z "$STALE_CONF" ] || echo "Inactive $CONF ignored; Install moves it to $STATE/main.conf.inactive.before."
        elif own_startup; then
            echo "J5 startup hook: created by aa_carplay_vol_patch."
        else
            echo "J5 startup hook: from another mod (kept)."
        fi
    fi
    if runtime_table "$TABLE"; then
        echo "AA persistence: direct atomic table value save enabled."
        echo "Saved AA gain in boot table: $saved"
        echo "Saved CarPlay gain in boot table: $saved_carplay"
    else
        echo "AA persistence: original or legacy table (no AA value save)."
    fi
    echo "Menu: namespace 0x01a900d8, key 84 AA music (connection 156), key 85 CarPlay music (connection 162)."
    echo "This checks files and startup selection, not the running process or sound output."
}

ACTION=${1:-status}
select_layout
echo "Layout: $LAYOUT"

case $ACTION in
    install) install ;;
    uninstall) uninstall ;;
    status)
        echo "aa_carplay_vol_patch $PATCH_VERSION"
        status
        ;;
    *) die "usage: aa_carplay_vol_patch.sh [status|install|uninstall]" ;;
esac
