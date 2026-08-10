#!/usr/bin/env bash
# Report what a display link is actually delivering, and score it out of 10.
#
# Works on any connected HDMI or DisplayPort connector, direct or through a
# DP->HDMI converter. With no argument it does every connected connector.
#
#   ./inspect-link.sh                 # everything connected
#   ./inspect-link.sh DP-1            # one connector
#   ./inspect-link.sh --no-sudo       # stay unprivileged, skip the elevation
#
# Read-only: no modeset, no module load, no writes. Safe against a live session.
#
# Root is optional but changes what can be seen. debugfs is 0700, and that is
# where the link state lives, so an unprivileged run cannot tell DSC from
# uncompressed and says so rather than guessing. Run unprivileged it therefore
# ELEVATES ITSELF -- see below -- and falls back to the degraded report if that
# does not work, rather than failing.
#
# ---------------------------------------------------------------------------
# THE TRAP THIS SCRIPT EXISTS TO AVOID
#
# With the TV off, a DP->HDMI converter holds HPD asserted and answers EDID
# from cache. DRM then reports `connected`, `enabled` and a full mode list --
# measured on this machine with the C9 in standby: 53 modes, all of it a lie.
# Anything derived from it reads as a healthy 4K120 link.
#
# CEC is the one channel that tells the truth: the TV answers
# GIVE_DEVICE_POWER_STATUS with `standby` in ~20 ms while in that state. So
# when a CEC adapter exists, this script asks, and REFUSES TO SCORE a link
# whose sink is not awake. A number produced against a sleeping TV would be
# worse than no number, because it looks exactly like a real one.
# ---------------------------------------------------------------------------
set -uo pipefail

C1='\033[1;36m'; C2='\033[1;33m'; C3='\033[1;31m'; C4='\033[1;32m'; C0='\033[0m'
say()  { printf "\n${C1}== %s${C0}\n" "$*"; }
row()  { printf '  %-26s %s\n' "$1" "$2"; }
warn() { printf "${C2}  ! %s${C0}\n" "$*"; }
bad()  { printf "${C3}  x %s${C0}\n" "$*"; }

ROOT=0; [[ $EUID -eq 0 ]] && ROOT=1
HAVE_EDID_DECODE=0; command -v edid-decode >/dev/null && HAVE_EDID_DECODE=1

# ------------------------------------------------------------------ elevation
# Half the report lives in debugfs and debugfs is 0700, so this re-runs itself
# under sudo. Elevation is best effort: unlike the installers, a failure here is
# not fatal, because a partial capability report still answers most questions.
# The TTY-vs-askpass reasoning lives in lib/elevate.sh.
# Shared self-elevation (lib/elevate.sh): provides elevate() and need_root().
# Walks up to the repo root so this works at any directory depth.
_lib() {
    local d; d=$(readlink -f "${BASH_SOURCE[0]}"); d=${d%/*}
    while [[ $d != / ]]; do
        [[ -r $d/lib/elevate.sh ]] && { printf '%s\n' "$d/lib/elevate.sh"; return 0; }
        d=${d%/*}
    done
    return 1
}
_l=$(_lib) && source "$_l"

# --------------------------------------------------------------- connectors
list_connected() {
    local c
    for c in /sys/class/drm/card*-*/; do
        [[ $(cat "$c/status" 2>/dev/null) == connected ]] || continue
        basename "$c" | sed 's/^card[0-9]*-//'
    done
}

# card0-DP-1 -> sysfs dir; a connector name alone is ambiguous across cards
# only if two GPUs expose the same name, which amdgpu does not do.
sysfs_for() {
    local n=$1 c
    for c in /sys/class/drm/card*-"$n"/; do [[ -d $c ]] && { echo "${c%/}"; return; }; done
    return 1
}

# <conn>/device resolves to .../drm/cardN, so the PCI address is two levels up.
pci_for() { basename "$(readlink -f "$1/device/../..")"; }
cardnum_for() { basename "$1" | sed 's/^card\([0-9]*\)-.*/\1/'; }

# ------------------------------------------------------------------ scoring
# Ten points, weighted by what actually changes the picture or the feel of a
# game on a TV. Deliberately NOT a bandwidth score: a link that hits 4K120 by
# compressing hard is not the equal of one that does it uncompressed, and a
# gaming machine without VRR has given up more than it has with 8-bit colour.
declare -A SCORE_MAX=(
    [mode]=2 [uncompressed]=2 [depth]=1 [vrr]=2 [hdr]=1 [allm]=1 [cec]=1
)
declare -A SCORE_GOT SCORE_WHY
UNKNOWNS=0

award() { # key points why
    SCORE_GOT[$1]=$2; SCORE_WHY[$1]=$3
}
unknown() { # key why
    SCORE_GOT[$1]=0; SCORE_WHY[$1]="UNKNOWN -- $2"; UNKNOWNS=$((UNKNOWNS+1))
}

# ------------------------------------------------------------ EDID features
# Parsed from edid-decode rather than the raw bytes: the CTA block layout has
# too many optional data blocks to index into safely by hand.
parse_edid() {
    local dir=$1
    EDID_OK=0; SINK_NAME='?'; E_VRRMIN=''; E_VRRMAX=''; E_ALLM=0; E_HDR10=0
    E_HLG=0; E_DV=0; E_MAXFRL=''; E_MAXTMDS=''; E_BEST=''; E_DEEP=0

    [[ -r $dir/edid ]] || return 1
    # sysfs binary attributes report size 0, so never test with -s: read it.
    local raw; raw=$(cat "$dir/edid" 2>/dev/null | wc -c)
    [[ ${raw:-0} -gt 0 ]] || return 1
    [[ $HAVE_EDID_DECODE -eq 1 ]] || return 1

    local d; d=$(edid-decode < "$dir/edid" 2>/dev/null) || return 1
    EDID_OK=1

    SINK_NAME=$(sed -n "s/.*Display Product Name: '\(.*\)'.*/\1/p" <<<"$d" | head -1)
    E_VRRMIN=$(sed -n 's/.*VRRmin: \([0-9]*\) Hz.*/\1/p' <<<"$d" | head -1)
    E_VRRMAX=$(sed -n 's/.*VRRmax: \([0-9]*\) Hz.*/\1/p' <<<"$d" | head -1)
    grep -q 'Supports Auto Low-Latency Mode' <<<"$d" && E_ALLM=1
    grep -q 'SMPTE ST2084'                   <<<"$d" && E_HDR10=1
    grep -q 'Hybrid Log-Gamma'                <<<"$d" && E_HLG=1
    grep -q 'Vendor-Specific Video Data Block (Dolby)' <<<"$d" && E_DV=1
    grep -qE 'DC_30bit|BT2020RGB'             <<<"$d" && E_DEEP=1
    E_MAXFRL=$(sed -n 's/.*Max Fixed Rate Link: \(.*\)/\1/p'  <<<"$d" | head -1)
    E_MAXTMDS=$(sed -n 's/.*Maximum TMDS Character Rate: \([0-9]*\) MHz.*/\1/p' <<<"$d" | head -1)
    # Best timing the sink advertises, by pixel clock.
    E_BEST=$(grep -oE '[0-9]+x[0-9]+ +[0-9]+\.[0-9]+ Hz' <<<"$d" \
             | awk '{gsub(/ +/," ");print}' | sort -t' ' -k2 -rn | head -1)
    return 0
}

# ------------------------------------------------------------- sink liveness
# Returns 0 = awake, 1 = asleep, 2 = cannot tell.
sink_awake() {
    local conn=$1 dev out st
    for dev in /dev/cec*; do
        [[ -e $dev ]] || continue
        [[ $(cec-ctl -d "$dev" 2>/dev/null | sed -n 's/.*Adapter Name *: *//p') == "$conn" ]] || continue
        out=$(timeout 15 cec-ctl -d "$dev" --to 0 --give-device-power-status 2>/dev/null)
        st=$(sed -n 's/.*pwr-state: \([a-z-]*\).*/\1/p' <<<"$out" | head -1)
        CEC_DEV=$dev; CEC_PWR=${st:-no-reply}
        case "$st" in
            on)                   return 0 ;;
            standby|to-standby)   return 1 ;;
            to-on)                return 0 ;;
            *)                    return 2 ;;
        esac
    done
    CEC_DEV=''; CEC_PWR=''
    return 2
}

# ------------------------------------------------------------------- report
inspect() {
    local conn=$1 dir pci card D
    dir=$(sysfs_for "$conn") || { bad "no such connector: $conn"; return 1; }
    pci=$(pci_for "$dir"); card=$(cardnum_for "$dir")
    D=/sys/kernel/debug/dri/$card/$conn

    SCORE_GOT=(); SCORE_WHY=(); UNKNOWNS=0

    printf "\n${C1}#### %s  (card%s, %s)${C0}\n" "$conn" "$card" "$pci"

    # --- liveness first: everything below is worthless if the sink is asleep
    sink_awake "$conn"; local live=$?
    parse_edid "$dir"

    say "Sink"
    row "connector type" "$(sed 's/-[0-9]*$//' <<<"$conn")"
    row "drm status" "$(cat "$dir/status")"
    row "drm enabled" "$(cat "$dir/enabled" 2>/dev/null)"
    row "modes offered" "$(wc -l < "$dir/modes")"
    if [[ $EDID_OK -eq 1 ]]; then
        row "sink name" "${SINK_NAME:-<unnamed>}"
        row "best advertised timing" "${E_BEST:-?}"
    else
        warn "no readable EDID -- sink capabilities unknown"
    fi
    case $live in
        0) row "sink power (CEC)" "on" ;;
        1) row "sink power (CEC)" "STANDBY" ;;
        2) [[ -n ${CEC_DEV:-} ]] && row "sink power (CEC)" "no reply" \
                                 || row "sink power (CEC)" "no CEC adapter on this connector" ;;
    esac

    if [[ $live -eq 1 && $FORCE -eq 0 ]]; then
        echo
        bad "SINK IS IN STANDBY -- not scoring this link."
        bad "DRM still reports connected/enabled with a full mode list because the"
        bad "converter holds HPD and serves EDID from cache. Every reading below"
        bad "that line would describe a link that is not carrying a picture."
        bad "Turn the TV on and re-run, or pass --force to score it anyway."
        return 0
    fi
    [[ $live -eq 1 && $FORCE -eq 1 ]] && \
        warn "--force: sink is in STANDBY, every number below is meaningless"

    # --- capability, from the sink's own EDID
    say "Sink capability (EDID)"
    if [[ $EDID_OK -eq 1 ]]; then
        row "HDMI VRR range" "$( [[ -n $E_VRRMIN ]] && echo "$E_VRRMIN-$E_VRRMAX Hz" || echo 'not advertised')"
        row "ALLM" "$( ((E_ALLM)) && echo yes || echo no)"
        row "HDR10 (ST2084)" "$( ((E_HDR10)) && echo yes || echo no)"
        row "HLG" "$( ((E_HLG)) && echo yes || echo no)"
        row "Dolby Vision" "$( ((E_DV)) && echo yes || echo no)"
        [[ -n $E_MAXTMDS ]] && row "max TMDS" "$E_MAXTMDS MHz"
        [[ -n $E_MAXFRL  ]] && row "max FRL" "$E_MAXFRL"
    else
        warn "skipped -- no EDID"
    fi

    # --- what the link is actually doing
    say "Delivered"
    local dsc='' bpp='' lanes='' rate='' frl=''
    if [[ $ROOT -eq 1 && -d $D ]]; then
        [[ -r $D/dsc_clock_en ]] && dsc=$(tr -d '\0' < "$D/dsc_clock_en" | tr -d '\n ')
        [[ -r $D/dsc_bits_per_pixel ]] && bpp=$(tr -d '\0' < "$D/dsc_bits_per_pixel" | tr -d '\n ')
        if [[ -r $D/link_settings ]]; then
            local ls; ls=$(tr -d '\0' < "$D/link_settings" | tr '\n' ' ')
            lanes=$(sed -n 's/.*Current: *\([0-9]*\) *\(0x[0-9a-f]*\).*/\1/p' <<<"$ls")
            rate=$(sed  -n 's/.*Current: *\([0-9]*\) *\(0x[0-9a-f]*\).*/\2/p' <<<"$ls")
        fi
        # FRL lives on the HDMI stream encoder; the HPO row is empty on a
        # converter link because the PCON negotiates FRL on its own HDMI side.
        if [[ -r /sys/kernel/debug/dri/$card/amdgpu_dm_dtn_log ]]; then
            frl=$(grep -A1 '^HPO:' "/sys/kernel/debug/dri/$card/amdgpu_dm_dtn_log" 2>/dev/null | tail -1 | tr -s ' ')
        fi
    fi

    if [[ -n $lanes ]]; then
        local human
        case "$rate" in
            0x06) human='RBR 1.62 Gbps/lane'  ;; 0x0a) human='HBR 2.7 Gbps/lane'  ;;
            0x14) human='HBR2 5.4 Gbps/lane'  ;; 0x1e) human='HBR3 8.1 Gbps/lane' ;;
            *)    human="rate code $rate"     ;;
        esac
        row "DP link" "$lanes lanes, $human"
    elif [[ $ROOT -eq 0 ]]; then
        row "DP link" "unknown (needs root)"
    fi

    if [[ -n $dsc ]]; then
        if [[ $dsc == 1 ]]; then
            # dsc_bits_per_pixel is in 1/16 bpp. Ratio against 30 bpp source,
            # carried in tenths so it prints as e.g. 2.5:1 without floats.
            local r=$(( ${bpp:-0} > 0 ? 4800 / ${bpp:-1} : 0 ))
            row "compression" "DSC on, $(( ${bpp:-0} / 16 )) bpp ($((r/10)).$((r%10)):1 from 30 bpp)"
        else
            row "compression" "none (DSC off)"
        fi
    elif [[ $ROOT -eq 0 ]]; then
        row "compression" "unknown (needs root)"
    fi
    [[ -n $frl ]] && row "HDMI FRL (HPO)" "$frl"

    # bpc / colourspace / HDR come from DRM properties, no root needed
    local props vrrcap bpc cspace hdrblob
    props=$(modetest -M amdgpu -D "$pci" -c 2>/dev/null | awk -v c="$conn" '
        $0 ~ "connected\t"c { f=1 } f && /^[0-9]+\t[0-9]+\t(dis)?connected/ && $0 !~ c { f=0 } f')
    vrrcap=$(awk '/vrr_capable/{g=1} g&&/value:/{print $2; exit}' <<<"$props")
    cspace=$(awk '/Colorspace:/{g=1} g&&/value:/{print $2; exit}' <<<"$props")
    hdrblob=$(awk '/HDR_OUTPUT_METADATA/{g=1} g&&/value:/{print $2; exit}' <<<"$props")
    row "Colorspace" "$(case "${cspace:-}" in 9) echo 'BT2020_RGB (HDR path active)';; 10) echo 'BT2020_YCC';; 0) echo 'Default (SDR)';; *) echo "${cspace:-?}";; esac)"

    say "VRR"
    row "vrr_capable" "${vrrcap:-?}"
    if [[ $ROOT -eq 1 && -r $D/vrr_range ]]; then
        row "vrr_range" "$(tr -d '\0' < "$D/vrr_range" | tr '\n' ' ')"
    fi
    # If a converter is in the path, say which of amdgpu's three conditions fail.
    if [[ $ROOT -eq 1 && -r /dev/drm_dp_aux$((card)) ]]; then
        local AUX=/dev/drm_dp_aux$((card)) oui devid dsp asy
        oui=$(dd if=$AUX bs=1 skip=$((16#500)) count=3 2>/dev/null | xxd -p | tr -d '\n')
        devid=$(dd if=$AUX bs=1 skip=$((16#503)) count=6 2>/dev/null | tr -d '\0')
        if [[ -n ${devid// /} ]]; then
            dsp=$(dd if=$AUX bs=1 skip=$((16#007)) count=1 2>/dev/null | xxd -p | tr -d '\n')
            asy=$(dd if=$AUX bs=1 skip=$((16#2214)) count=1 2>/dev/null | xxd -p | tr -d '\n')
            row "converter" "$devid (OUI 0x${oui^^})"
            row "  MSA timing ignore" "$(( (16#${dsp:-0} >> 6) & 1 ))"
            row "  ADAPTIVE_SYNC_SDP" "$(( 16#${asy:-0} & 1 ))"
            case "${oui^^}" in
                0060AD|00E04C|90CC24|001CF8|001FF2) row "  amdgpu whitelist" "yes" ;;
                *) row "  amdgpu whitelist" "NO -- VRR refused regardless of the two bits above" ;;
            esac
        fi
    fi

    say "CEC"
    if [[ -n ${CEC_DEV:-} ]]; then
        row "adapter" "$CEC_DEV"
        row "TV power state" "$CEC_PWR"
    else
        row "adapter" "none -- amdgpu registers no CEC on its own HDMI ports"
    fi

    # ------------------------------------------------------------- scoring
    # mode
    if [[ $EDID_OK -eq 1 && -n $E_BEST ]]; then
        # The sysfs mode list carries resolutions only, no refresh rates, so
        # this can check that the sink's highest-pixel-clock resolution survived
        # mode pruning -- not that its refresh rate did.
        if grep -q "^$(cut -dx -f1 <<<"$E_BEST" | tr -d ' ')x" "$dir/modes" 2>/dev/null; then
            award mode 2 "sink's best timing ($E_BEST) is offered"
        else
            award mode 1 "sink's best timing not in the mode list"
        fi
    else
        unknown mode "no EDID to compare against"
    fi
    # uncompressed
    if [[ -n $dsc ]]; then
        [[ $dsc == 1 ]] && award uncompressed 0 "DSC active at $((${bpp:-0}/16)) bpp" \
                        || award uncompressed 2 "uncompressed"
    else
        unknown uncompressed "needs root to read dsc_clock_en"
    fi
    # depth -- scored on reachable capability like the rest of the rubric, not
    # on what is engaged this second: HDR and wide gamut are toggled per app,
    # so a machine sitting on a desktop would otherwise score itself down.
    if [[ $EDID_OK -eq 1 ]]; then
        ((E_DEEP)) && award depth 1 "10-bit / BT.2020 reachable" \
                   || award depth 0 "sink advertises no deep colour"
    else
        unknown depth "no EDID"
    fi
    # vrr
    case "${vrrcap:-}" in
        1) award vrr 2 "VRR available" ;;
        0) if [[ $EDID_OK -eq 1 && -n $E_VRRMIN ]]; then
               award vrr 0 "sink advertises $E_VRRMIN-$E_VRRMAX Hz but the driver refuses it"
           else
               award vrr 0 "not available"
           fi ;;
        *) unknown vrr "could not read vrr_capable" ;;
    esac
    # hdr
    if [[ $EDID_OK -eq 1 ]]; then
        ((E_HDR10)) && award hdr 1 "HDR10 supported and reachable" || award hdr 0 "sink has no HDR10"
    else
        unknown hdr "no EDID"
    fi
    # allm
    if [[ $EDID_OK -eq 1 ]]; then
        ((E_ALLM)) && award allm 1 "sink supports ALLM" || award allm 0 "sink has no ALLM"
    else
        unknown allm "no EDID"
    fi
    # cec
    [[ -n ${CEC_DEV:-} ]] && award cec 1 "CEC adapter present and answering" \
                          || award cec 0 "no CEC on this path"

    say "Rating"
    echo "  (what this link makes AVAILABLE, not what an app is using right now)"
    local total=0 max=0 k
    for k in mode uncompressed depth vrr hdr allm cec; do
        total=$((total + ${SCORE_GOT[$k]:-0})); max=$((max + SCORE_MAX[$k]))
        printf '  %-14s %s/%s  %s\n' "$k" "${SCORE_GOT[$k]:-0}" "${SCORE_MAX[$k]}" "${SCORE_WHY[$k]:-}"
    done
    echo
    local label
    if   [[ $total -ge 9 ]]; then label='excellent -- little left on the table'
    elif [[ $total -ge 7 ]]; then label='good -- one real compromise'
    elif [[ $total -ge 5 ]]; then label='workable -- several features unavailable'
    else                          label='poor -- the link is well short of the sink'
    fi
    printf "  ${C4}SCORE: %s/%s${C0}  %s\n" "$total" "$max" "$label"
    if [[ $UNKNOWNS -gt 0 ]]; then
        echo
        warn "$UNKNOWNS component(s) unknown and scored 0 -- this is a FLOOR, not a rating."
        [[ $ROOT -eq 0 ]] && warn "Re-run with sudo -A for the link state."
    fi
}

# ---------------------------------------------------------------------- main
FORCE=0; NO_SUDO=0
targets=()
for a in "$@"; do
    case "$a" in
        --force) FORCE=1 ;;
        --no-sudo) NO_SUDO=1 ;;
        -h|--help) sed -n '2,18p' "${BASH_SOURCE[0]}" | sed 's/^# \?//'; exit 0 ;;
        -*) bad "unknown option: $a"; exit 1 ;;
        *)  targets+=("$a") ;;
    esac
done
# Elevate before doing any work, passing the original arguments through so the
# root run behaves identically. Not fatal if it fails -- see the note above.
elevate "$@" || warn "continuing unprivileged -- link state will be unknown"
ROOT=0; [[ $EUID -eq 0 ]] && ROOT=1

if [[ ${#targets[@]} -eq 0 ]]; then
    mapfile -t targets < <(list_connected)
    [[ ${#targets[@]} -eq 0 ]] && { bad "no connected connectors"; exit 1; }
fi
for t in "${targets[@]}"; do inspect "$t"; done
echo
