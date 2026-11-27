#!/bin/ksh
# Runs once on audio-service startup, before the native backend accepts GEM RPC.
# Recover only our reserved staging file after an interrupted write. The live
# compiled.dat is always either the previous or the newly committed full table.
set -eu
STAGE=/net/imx6/tsd/var/audio/audiotable/compiled.dat.aa-gain-new
FAILED=/net/imx6/tsd/var/audio/audiotable/compiled.dat.aa-gain-failed
LOCK=/net/imx6/tsd/var/audio/audiotable/compiled.dat.aa-gain-lock
IDLE=/net/imx6/tsd/var/audio/audiotable/compiled.dat.aa-gain-idle
OPERATION_LOCK=/net/imx6/tsd/var/.aa_volume.lock
# Recovery shares the installer's mkdir lock. If an installer owns it, leave
# its runtime lock and staging files untouched and start audio normally. The
# backend rejects slider writes until the installer releases its runtime lock.
# Do not test existence then recover: installer acquisition could race that test.
if mkdir "$OPERATION_LOCK" 2>/dev/null; then
    trap 'rmdir "$OPERATION_LOCK"' 0
    trap 'exit 1' HUP INT TERM
    if [ -e "$STAGE" ] || [ -L "$STAGE" ]; then
        [ -f "$STAGE" ] && [ ! -L "$STAGE" ] || exit 1
        mv -f "$STAGE" "$FAILED"
        sync
    fi
    if [ -e "$LOCK" ] || [ -L "$LOCK" ]; then
        [ -f "$LOCK" ] && [ ! -L "$LOCK" ] || exit 1
        mv -f "$LOCK" "$IDLE"
        sync
    fi
    rmdir "$OPERATION_LOCK"
    trap - 0 HUP INT TERM
fi
exec /net/imx6/tsd/var/aa_volume/tsd.mibstd2.audio.audiomgr.persistent.thin "$@"
