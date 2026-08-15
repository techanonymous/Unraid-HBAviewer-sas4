#!/bin/bash
# Shared HBA invocation — the single seam to the lsiutil binary.
#
# hba_query owns only the universal part: where the binary lives. Everything
# else (port, -e expert flag, -a menu args, -b, stdin) passes through, so the
# same function covers every call style:
#   hba_query -p"$PORT" -a 25,2,0,0     # menu command on a port
#   printf '0\n' | hba_query            # interactive banner, no port
#   hba_query -b                        # board info, no port
#   hba_query -e -p"$PORT" -a 35,0      # expert-mode command
#
# require_binary emits the not-found error JSON and returns non-zero. Composers
# call it BEFORE the query|parse pipe so the error reaches PHP, never a parser.

LSIUTIL="${LSIUTIL:-/usr/local/emhttp/plugins/hbaviewer/hbaviewer.x86_64}"

require_binary() {
    if [ ! -x "$LSIUTIL" ]; then
        echo '{"error":"lsiutil binary not found. Re-install the plugin."}'
        return 1
    fi
}

hba_query() { "$LSIUTIL" "$@"; }

# Every storcli-family binary on the box, deduped, in probe order — both flavors
# mixed together on purpose. WHICH one can actually read the hardware is decided
# by use_storcli(), never by position in this list: the dkaser/unraid-storcli
# plugin symlinks BOTH /usr/local/bin/storcli (classic 3404) and
# /usr/local/bin/storcli2 (storcli2Lite), so on a 9600 box the classic tool wins
# any name-ordered search and then enumerates zero controllers.
# /opt/MegaRAID/storcli2/storcli2 is where Broadcom's own .deb/.rpm installs it.
storcli_candidates() {
    local c
    for c in storcli storcli64 storcli2 \
             /usr/local/sbin/storcli /usr/local/sbin/storcli64 \
             /usr/local/bin/storcli /usr/local/bin/storcli64 /usr/local/bin/storcli2 \
             /usr/sbin/storcli /usr/sbin/storcli64 \
             /opt/MegaRAID/storcli2/storcli2; do
        if   command -v "$c" >/dev/null 2>&1; then command -v "$c"
        elif [ -x "$c" ];                     then echo "$c"
        fi
    done | awk '!seen[$0]++'
}

# First storcli-family binary present. A PRESENCE test only — for "is any storcli
# installed at all?" (get_hba_info.sh's refusal guard). To get the one that can
# read THIS card, call use_storcli. Honors a preset $STORCLI.
find_storcli() {
    if [ -n "$STORCLI" ]; then echo "$STORCLI"; return; fi
    storcli_candidates | head -1
}

# "storcli2" (SAS4 / 9600, mpi3mr) or "storcli" (SAS3/3.5, mpt3sas), read from the
# binary's own banner — StorCLI2 prints "StorCli2 SAS Customization Utility".
# The FILENAME is not a usable signal: the storcli2 build ships as
# storcli2Lite-8.14 and is symlinked to whatever name the packager chose.
# $STORCLI_FLAVOR overrides (tests).
storcli_flavor() {
    [ -n "$STORCLI_FLAVOR" ] && { echo "$STORCLI_FLAVOR"; return; }
    case "$( ( cd "${STORCLI_CWD:-/tmp}" 2>/dev/null || cd /; "$1" version 2>/dev/null ) | head -5)" in
        *StorCli2*|*StorCLI2*|*storcli2*) echo storcli2 ;;
        *)                                echo storcli  ;;
    esac
}

# Locate the per-generation flash tool — sibling of find_storcli, same posture
# (proprietary, never bundled: probe PATH + common sbin dirs + the plugin's
# persisted upload dir). $1 = "sas2" | "sas3". Honors a preset $FLASHER (tests).
# Prints the resolved path, or nothing if not found.
find_flasher() {
    local gen="$1" tool c
    if [ -n "$FLASHER" ]; then echo "$FLASHER"; return; fi
    case "$gen" in
        sas2) tool=sas2flash ;;
        sas3) tool=sas3flash ;;
        *)    return 1 ;;
    esac
    for c in "$tool" \
             "/usr/local/sbin/$tool" "/usr/local/bin/$tool" "/usr/sbin/$tool" \
             "/boot/config/plugins/hbaviewer/tools/$tool"; do
        command -v "$c" >/dev/null 2>&1 && { command -v "$c"; return; }
        [ -x "$c" ] && { echo "$c"; return; }
    done
}

# True (and export a resolved $STORCLI + $STORCLI_FLAVOR) iff some storcli-family
# binary enumerates a controller. The routing test every tab composer uses.
#
# Probes CANDIDATES rather than trusting the first name found: a 9600 box has the
# classic storcli installed too and it answers "Number of Controllers = 0" there,
# which is indistinguishable from "no card" unless the other flavor is tried.
# Both flavors print that same line, so the count parse is shared.
_storcli_enumerates() {   # $1 = binary -> prints the count, non-zero if none
    local n
    n=$( ( cd "${STORCLI_CWD:-/tmp}" 2>/dev/null || cd /; "$1" show 2>/dev/null ) \
         | grep -m1 'Number of Controllers' | grep -oE '[0-9]+')
    [ -n "$n" ] && [ "$n" -gt 0 ] || return 1
    echo "$n"
}
use_storcli() {
    local sc
    # A preset override is honored verbatim and never probed past — the suite
    # points $STORCLI at a stub, and falling through to a real binary on the
    # runner's PATH would make the fixture silently not the thing under test.
    if [ -n "$STORCLI" ]; then
        _storcli_enumerates "$STORCLI" >/dev/null || return 1
        STORCLI_FLAVOR=$(storcli_flavor "$STORCLI")
        export STORCLI STORCLI_FLAVOR; return 0
    fi
    while read -r sc; do
        [ -n "$sc" ] || continue
        _storcli_enumerates "$sc" >/dev/null || continue
        STORCLI="$sc"; STORCLI_FLAVOR=$(storcli_flavor "$sc")
        export STORCLI STORCLI_FLAVOR; return 0
    done < <(storcli_candidates)
    return 1
}

# Run a storcli-family tool from a scratch directory.
#
# Both tools write a debug log — storcli.log / storcli2.log — into their CURRENT
# WORKING DIRECTORY, unasked. The composers inherit the web server's cwd, which
# is the plugin's own scripts/ dir, so this quietly dropped ~230 KB per
# invocation into /usr/local/emhttp/plugins/hbaviewer/scripts/ and grew a
# rotation file beside it. That directory is tmpfs — it is RAM — and the log
# contains drive serial numbers, so it is both a memory leak and a copy of
# hardware identifiers in a place nothing expects them.
# `nolog` suppresses the file outright and is passed by the storcli2 callers;
# this wrapper is the belt to that braces, and covers any call that cannot use
# the argument (the flavor probe, which runs before the flavor is known).
storcli_run() {
    ( cd "${STORCLI_CWD:-/tmp}" 2>/dev/null || cd /; "$STORCLI" "$@" )
}

# Controller count from storcli's enumeration — the single parse of
# "Number of Controllers" that every storcli path shares. Empty if none.
# By the time this runs the flavor is known, so the storcli2 case can suppress
# the debug log outright. The two calls that cannot — the enumeration probe and
# the version banner that DETERMINES the flavor — still write one, which is why
# storcli_run points them at /tmp: bounded by the tool's own ~1 MB rotation, in
# RAM, swept at reboot, and out of the plugin directory.
storcli_count() {
    if [ "$STORCLI_FLAVOR" = storcli2 ]; then
        storcli_run show nolog 2>/dev/null | grep -m1 'Number of Controllers' | grep -oE '[0-9]+'
    else
        storcli_run show 2>/dev/null | grep -m1 'Number of Controllers' | grep -oE '[0-9]+'
    fi
}

# "00:82:00:0" (both storcli flavors print domain:bus:device:function) -> the
# sysfs directory "…/0000:82:00.0". Neither tool reports the PCIe link state that
# the Overview and Health tabs judge, so both read it out of sysfs, and both need
# this conversion: four-digit hex domain, a dot before the function.
# SYS_PCI_ROOT is overridable so the suite can point it at a fixture tree.
# Prints nothing for an unparseable address rather than a half-built path.
pci_addr_to_sysfs_dir() {   # $1 = "dom:bus:dev:fn"
    local dom bus dev fn
    [ -n "$1" ] || return 1
    IFS=: read -r dom bus dev fn <<< "$1"
    [ -n "$bus" ] && [ -n "$dev" ] || return 1
    printf '%s/%s' "${SYS_PCI_ROOT:-/sys/bus/pci/devices}" \
        "$(printf '%04x:%s:%s.%d' "0x${dom:-0}" "$bus" "$dev" "0x${fn:-0}")"
}

# Driver + version string for the driver that actually claimed a controller.
#
# Keyed on the scsi_host personality, NOT on which module happens to be loaded.
# Unraid 7.3 builds mpt3sas INTO the kernel, so /sys/module/mpt3sas/version is
# readable on a box whose only HBA is a 9600 on mpi3mr — the old module-first
# order reported "mpt3sas 54.100.00.00" for that card. Same class of bug as the
# one hba_personalities exists to avoid, one level up.
# The version file is still where the version comes from; the personality only
# decides WHICH module to ask about.
hba_driver() {
    local p
    for p in $(hba_personalities); do
        if [ -r "/sys/module/$p/version" ]; then echo "$p $(cat "/sys/module/$p/version")"
        else echo "$p"
        fi
        return
    done
}

# Which driver personality claimed each controller — one line per SAS host, empty
# if there is no supported HBA. This, NOT /sys/module/*, is the honest generation
# signal: the merged mpt3sas driver registers SAS2 cards under the mpt2sas
# personality, so issue #3's SAS9207-8i has no mpt2sas module at all yet reports
# proc_name=mpt2sas.
# mpi3mr is the SAS4 driver (9600 series). It is a genuinely different stack, not
# another mpt personality: it needs StorCLI2, and on an eHBA-personality card it
# registers NO SAS transport class at all (measured on a 9600-24i: sas_phy,
# sas_port, sas_device and sas_end_device all empty, /dev/bsg nodes named by SCSI
# h:c:t:l rather than SAS address). Anything reading those paths must treat their
# absence as "unknown", never as zero.
# SYS_SCSI_HOST is overridable so the suite can point it at a fixture tree.
#
# hba_is_sas_proc is the ONE place the personality list lives. It was copy-pasted
# into six scripts, and adding mpi3mr meant finding all six — a card the plugin
# cannot see is invisible in a way that produces no error, just an empty tab.
hba_is_sas_proc() { case "$1" in mpt3sas|mpt2sas|mptsas|mpi3mr) return 0 ;; esac; return 1; }

hba_personalities() {
    local h p
    for h in "${SYS_SCSI_HOST:-/sys/class/scsi_host}"/host*/; do
        p=$(cat "${h}proc_name" 2>/dev/null)
        hba_is_sas_proc "$p" && echo "$p"
    done
}

# True iff any controller is on the mpt2sas/mptsas personality — i.e. the bundled
# lsiutil 1.70 has a card it can reach. Verified on issue #3's mpt3sas-only box:
# /dev/mptctl exists there and lsiutil read the IOC temperature fine.
hba_has_sas2() { case "$(hba_personalities)" in *mpt2sas*|*mptsas*) return 0 ;; esac; return 1; }

# True iff any controller is on the mpt3sas personality — genuine SAS3/3.5, needs
# storcli. Both can be true on a box with one card of each generation.
hba_has_sas3() { case "$(hba_personalities)" in *mpt3sas*) return 0 ;; esac; return 1; }

# True iff any controller is on the mpi3mr personality — SAS4 (9600 series), needs
# StorCLI2. The bundled lsiutil cannot reach these at all: there is no /dev/mptctl
# path to them, so unlike the SAS2-vs-SAS3 case there is no "try it anyway".
hba_has_sas4() { case "$(hba_personalities)" in *mpi3mr*) return 0 ;; esac; return 1; }

# The backend seam. Chooses storcli / storcli2 / lsiutil ONCE, owns controller
# enumeration and the {"backend","driver","controllers":[...]} wrapper, so a
# composer only declares *what to run per controller*.
#   $1 = storcli fn: `fn <c>` prints controller c's JSON object ($STORCLI
#        resolved+exported, count already > 0).
#   $2 = lsiutil fn: prints the inner controller object(s) on success, OR
#        prints a top-level error JSON and returns non-zero to abort the wrap.
#   $3 = storcli2 fn (optional): same contract as $1, for the SAS4 tool whose
#        command set and output differ. Defaults to $1, so a composer that has
#        not been ported yet keeps its old behaviour instead of breaking.
# The emitted "backend" is the FLAVOR — endpoints branch on that field, never on
# which binary exists (a 9600 box has both installed).
hba_each() {
    local storcli_fn="$1" lsiutil_fn="$2" storcli2_fn="${3:-$1}" fn c count body rc
    if use_storcli; then
        count=$(storcli_count)
        if [ "$STORCLI_FLAVOR" = storcli2 ]; then fn="$storcli2_fn"; else fn="$storcli_fn"; fi
        printf '{"backend":"%s","driver":"%s","controllers":[' "${STORCLI_FLAVOR:-storcli}" "$(hba_driver)"
        for c in $(seq 0 $((count - 1))); do
            [ "$c" -gt 0 ] && printf ','
            "$fn" "$c"
        done
        printf ']}'
    else
        body=$("$lsiutil_fn"); rc=$?
        if [ "$rc" -ne 0 ]; then printf '%s' "$body"; return; fi
        printf '{"backend":"lsiutil","driver":"%s","controllers":[%s]}' "$(hba_driver)" "$body"
    fi
}
