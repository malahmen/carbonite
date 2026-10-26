#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# carbonite.sh — a fan curve for hwmon fans, applied through CoolerControl.
#
# The sibling of thermal-exhaust-port. That one exists because a Framework
# Desktop has no hwmon PWM at all, so it is its own daemon driving the EC via
# ectool. A desktop board with a Super I/O chip (an MSI board's NCT6687, say)
# is the opposite case: every header is a writable pwmN, and CoolerControl is
# already a good daemon for exactly that. What it lacks is a way to say "this
# curve, from these sensors, on these fans" without clicking through a GUI —
# and while every channel sits at "Unmanaged", the BIOS curve is in charge,
# which on these boards often means a header pinned at full speed.
#
# So this is NOT a daemon. It is a one-shot, gum-free, flag-driven CLI that
# writes a curve into CoolerControl over its REST API and reads it back:
#
#   function  carbonite-fn      the smoothing: hysteresis + response delay,
#                               applied only on the way down (one-sided, the
#                               thermal-exhaust-port behaviour)
#   profile   carbonite-g-N     one Graph profile per watched sensor
#   profile   carbonite         the curve: the Graph itself for one sensor, a
#                               Mix (max) of them for more
#   profile   carbonite-mN      the same curve, never below N% — for fans that
#                               stall at low duty (a channel given as ID@N)
#
# Plus pins: a channel held at a fixed duty whatever the temperature (an AIO
# pump). Which header carries the pump cannot be read from its label — on an
# MSI board the pump is often on CPU_FAN1 and the "Pump Fan" header carries the
# radiator fans — so nothing is ever chosen for you: `apply` needs --channels,
# and pins are asked for by name.
#
# CoolerControl persists all of it and re-applies it at boot. The single source
# of truth is CoolerControl itself — `status`, `curve` and `config` read the
# profiles back rather than keeping a copy here that could disagree. The one
# thing kept here is which fixed duties are carbonite's pins, so a fixed speed
# set in the GUI is never mistaken for one.
#
# Requirements: bash >= 4, curl, jq, a running coolercontrold, and an access
# token with write access (CoolerControl → Settings → Access Tokens), saved
# once with `carbonite.sh login` (it reads the token from stdin).
#
# The token can set any fan's duty, so it is never put on a command line:
# `ps` shows every process's argv to every user. curl gets the header from a
# config on its stdin (-K -), and login reads the token from stdin.
# -----------------------------------------------------------------------------

if [[ "${BASH_VERSINFO[0]:-0}" -lt 4 ]]; then
    echo "[error] bash 4+ required (you have ${BASH_VERSION})." >&2
    exit 1
fi

# No `set -e`: a failed API call is reported and handled where it happens.
set -uo pipefail

VERSION="1.1.0"

if [[ -t 2 ]]; then C_C=$'\e[36m'; C_G=$'\e[32m'; C_Y=$'\e[33m'; C_R=$'\e[31m'; C_N=$'\e[0m'
else C_C=""; C_G=""; C_Y=""; C_R=""; C_N=""; fi
info()       { printf '%s[info]%s  %s\n'  "$C_C" "$C_N" "$*" >&2; }
success()    { printf '%s[ok]%s    %s\n'  "$C_G" "$C_N" "$*" >&2; }
warn()       { printf '%s[warn]%s  %s\n'  "$C_Y" "$C_N" "$*" >&2; }
error()      { printf '%s[error]%s %s\n'  "$C_R" "$C_N" "$*" >&2; }
error_exit() { error "$*"; exit 1; }

# -----------------------------------------------------------------------------
# Configuration. Unlike thermal-exhaust-port there is no root daemon here, so
# the per-user XDG file is the right home: it only holds where CoolerControl is
# and the token to talk to it. The curve lives in CoolerControl.
# -----------------------------------------------------------------------------
CONF_DIR="${CARB_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/carbonite}"
CONF_FILE="${CONF_DIR}/config"

URL=""; TOKEN=""; TOKEN_SOURCE="none"; FILE_TOKEN=""; PINS=""
CURL="${CARB_CURL:-curl}"
SYSTEMCTL="${CARB_SYSTEMCTL:-systemctl}"

DEFAULT_CURVE="30:25 50:35 65:55 75:75 85:100"
CURVE=""; SENSORS=""; CHANNELS=""; PIN=""; HYST=""; DELAY=""
YES=0
ALLOW_STOP=0

PREFIX="carbonite"
FN_UID="${PREFIX}-fn"
TOP_UID="${PREFIX}"
DEFAULT_PROFILE_UID="0"   # CoolerControl's built-in "Default Profile": hands back to the board

# Other things known to write pwm on their own. Two writers on one pwmN fight
# silently, exactly the thermal-exhaust-port problem one level down.
CONFLICT_UNITS=(fancontrol.service fan2go.service thermal-exhaust-port.service
                nbfc_service.service nbfc.service)

_read_conf() {
    URL="${CARB_URL:-}"
    TOKEN="${CARB_TOKEN:-}"
    [[ -n "$TOKEN" ]] && TOKEN_SOURCE="env"
    if [[ -f "$CONF_FILE" ]]; then
        local key val
        # Parsed, never sourced: a config file is not a script.
        while IFS='=' read -r key val; do
            case "$key" in
                url)   [[ -z "$URL" ]] && URL="$val" ;;
                token) FILE_TOKEN="$val"
                       if [[ -z "$TOKEN" ]]; then TOKEN="$val"; TOKEN_SOURCE="file"; fi ;;
                pins)  PINS="$val" ;;
            esac
        done < "$CONF_FILE"
    fi
    URL="${URL:-http://127.0.0.1:11987}"
    URL="${URL%/}"
}

_valid_token() { [[ "$1" =~ ^[^[:space:][:cntrl:]]+$ ]]; }

# Writes what is on file, never a token that only came from the environment.
_write_conf() {
    mkdir -p "$CONF_DIR"
    local tmp; tmp="$(mktemp "${CONF_DIR}/.config.XXXXXX")"
    chmod 600 "$tmp"
    printf 'url=%s\ntoken=%s\npins=%s\n' "$URL" "$FILE_TOKEN" "$PINS" > "$tmp"
    mv -f "$tmp" "$CONF_FILE"
}

usage() {
    cat <<EOF
carbonite.sh ${VERSION} — a fan curve for hwmon fans, applied through CoolerControl

Usage: carbonite.sh COMMAND [flags]

Commands:
  login                    save a CoolerControl access token (needs write access),
                           read from stdin: a hidden prompt on a terminal, or piped
  check                    is the daemon reachable and is the token accepted
  status                   applied curve, sensors, channels, temps, fan RPM
  sensors                  every temperature source, TSV: id<TAB>device<TAB>label<TAB>degC<TAB>watched
  channels                 every fan channel, TSV: id<TAB>device<TAB>label<TAB>rpm<TAB>duty<TAB>control
                           (control: -  curve  curve:N (floor N%)  pin:N  fixed:N (set elsewhere))
  curve                    the applied curve as TSV: degC<TAB>duty
  simulate T...            walk a curve over temperatures, change nothing
  apply                    write the curve; --channels is the full list that follows it
  set-curve POINTS         change the applied curve, keep sensors, channels and floors
  pin ID@N...              hold channels at a fixed N% (an AIO pump: ID@100)
  unpin ID...              hand pinned channels back to the board
  release                  hand curve channels back to the board, delete the profiles
                           (pins are kept — unpin them by name)
  conflicts                other services that write pwm, TSV: unit<TAB>state
  config                   the resolved state as key=value
  version

Flags:
  --curve POINTS           degC:duty% points, ascending (default: ${DEFAULT_CURVE})
  --sensors "ID ..."       sensor ids from 'sensors' (default: CPU package + GPU)
  --channels "ID[@N] ..."  channels on the curve; @N = never below N% (required —
                           which header is a pump cannot be told from its label)
  --pin "ID@N ..."         with apply: pin these first, before any curve change
  --hyst N                 degC to fall before slowing down (default: 3)
  --delay N                seconds a drop must last before slowing down (default: 3)
  --allow-stop             let a curve that reaches 0% stop fans with no floor (@N);
                           without it apply and set-curve refuse such a curve
  --url URL                CoolerControl API (default: http://127.0.0.1:11987)
  --token TOKEN            deprecated: puts the token on argv, where ps shows it to
                           every user. Use 'login' (stdin) or \$CARB_TOKEN
  --yes                    do not ask (release, unpin)

Between points the duty is interpolated linearly, as CoolerControl does; below
the first point it holds the first duty, above the last it holds the last.
Channels left out of an apply that were on the curve go back to the board;
pins are only ever removed by 'unpin'.
Data goes to stdout, logs to stderr.
EOF
}

# -----------------------------------------------------------------------------
# The curve
# -----------------------------------------------------------------------------
declare -a CT=() CD=()

# parse_curve POINTS — fills CT/CD; returns 1 with a reason on stderr.
parse_curve() {
    CT=(); CD=()
    local p t d prev=-1 prevd=-1
    for p in $1; do
        [[ "$p" =~ ^([0-9]{1,3}):([0-9]{1,3})$ ]] || { error "bad point '${p}' — want degC:duty, e.g. 60:45"; return 1; }
        t=$((10#${BASH_REMATCH[1]})); d=$((10#${BASH_REMATCH[2]}))
        (( t <= 110 )) || { error "${t}C is past any sane limit"; return 1; }
        (( d <= 100 )) || { error "duty ${d}% is over 100"; return 1; }
        (( t > prev )) || { error "temperatures must rise: ${t}C after ${prev}C"; return 1; }
        # CoolerControl would silently raise a falling duty to the one before;
        # refusing it here means simulate never shows a curve that is not applied.
        (( d >= prevd )) || { error "duty must not fall as it gets hotter: ${d}% after ${prevd}%"; return 1; }
        CT+=("$t"); CD+=("$d"); prev=$t; prevd=$d
    done
    (( ${#CT[@]} >= 2 )) || { error "a curve needs at least two points"; return 1; }
    return 0
}

# _stop_below — the hottest temperature at which the parsed curve is at 0%
# (fans stopped), or nothing if it never reaches 0%. Below the first point
# the first duty holds, so a curve starting at 0% stops fans from cold.
_stop_below() {
    local i t=""
    for (( i = 0; i < ${#CT[@]}; i++ )); do (( CD[i] == 0 )) && t="${CT[i]}"; done
    printf '%s' "$t"
}

# _refuse_stopping_fans "SPEC ..." — a curve that reaches 0% stops every fan on
# it that has no floor (@N); refused unless --allow-stop says that is meant.
# A floor lifts the 0% for its fan (_floored_json), so floored fans pass.
_refuse_stopping_fans() {
    local t s bare=""
    t="$(_stop_below)"
    [[ -n "$t" ]] && (( ! ALLOW_STOP )) || return 0
    for s in $1; do [[ -n "$(_spec_n "$s")" ]] || bare+="$(_spec_id "$s") "; done
    [[ -n "$bare" ]] || return 0
    error_exit "the curve is at 0% up to ${t}C, which STOPS ${bare% } there. Give each a floor (ID@N, e.g. ID@20), or pass --allow-stop if they may stop."
}

# duty_at T — CoolerControl's interpolate_profile: clamp at the ends, linear
# between, rounded half away from zero.
duty_at() {
    local t="$1" n=${#CT[@]} i
    (( t <= CT[0] )) && { echo "${CD[0]}"; return; }
    (( t >= CT[n-1] )) && { echo "${CD[n-1]}"; return; }
    for (( i = 1; i < n; i++ )); do
        if (( t <= CT[i] )); then
            awk -v t="$t" -v t0="${CT[i-1]}" -v t1="${CT[i]}" -v d0="${CD[i-1]}" -v d1="${CD[i]}" \
                'BEGIN { v = d0 + (t - t0) / (t1 - t0) * (d1 - d0); printf "%d\n", int(v + 0.5) }'
            return
        fi
    done
}

_curve_json() {
    local i out="["
    for (( i = 0; i < ${#CT[@]}; i++ )); do out+="[${CT[i]},${CD[i]}],"; done
    printf '%s]' "${out%,}"
}

# -----------------------------------------------------------------------------
# The API
# -----------------------------------------------------------------------------
API_BODY=""; API_CODE=""

# _curl_config — the curl config carrying the token, for `curl -K -`. A -H on
# curl's argv would show the token to every user in `ps` for as long as the
# call runs (up to 15 s); a config on stdin is seen by curl alone. Quoted the
# way curl's config parser unquotes: \\ and \".
_curl_config() {
    [[ -n "$TOKEN" ]] || return 0
    local bs='\' q='"' t
    t="${TOKEN//"$bs"/"$bs$bs"}"; t="${t//"$q"/"$bs$q"}"
    printf 'header = "Authorization: Bearer %s"\n' "$t"
}

# _api METHOD PATH [JSON] — sets API_BODY/API_CODE; 0 on 2xx.
_api() {
    local method="$1" path="$2" data="${3:-}" out
    local -a args=(-sS -X "$method" -H "Accept: application/json" --max-time 15)
    [[ -n "$data" ]] && args+=(-H "Content-Type: application/json" --data "$data")
    # printf is a builtin: the token is never any process's argument.
    out="$(_curl_config | "$CURL" -K - "${args[@]}" -w $'\n%{http_code}' "${URL}${path}" 2>/dev/null)" || {
        API_BODY=""; API_CODE="000"; return 1; }
    API_CODE="${out##*$'\n'}"
    API_BODY="${out%$'\n'*}"
    [[ "$API_CODE" =~ ^2 ]]
}

# The daemon answers errors as {"error": "..."}; fall back to the raw body.
_api_err() {
    local msg
    msg="$(jq -r '.error // empty' <<<"$API_BODY" 2>/dev/null)"
    printf '%s' "${msg:-${API_BODY:-no response}} (HTTP ${API_CODE})"
}

_need_api() {
    command -v "$CURL" &>/dev/null || error_exit "curl is required."
    command -v jq &>/dev/null || error_exit "jq is required."
    _api GET /handshake || error_exit "CoolerControl is not answering at ${URL} — is coolercontrold running? (systemctl status coolercontrold)"
    [[ -n "$TOKEN" ]] || error_exit "no access token. Create one with write access in CoolerControl (Settings → Access Tokens), then: carbonite.sh login"
    _api GET /devices || error_exit "CoolerControl refused the token: $(_api_err)"
    DEVICES="$API_BODY"
}

DEVICES='{"devices":[]}'; STATUS='{"devices":[]}'; PROFILES='{"profiles":[]}'

_load_status()   { _api POST /status '{}' && STATUS="$API_BODY" || error_exit "could not read status: $(_api_err)"; }
_load_profiles() { _api GET /profiles && PROFILES="$API_BODY" || error_exit "could not read profiles: $(_api_err)"; }

# Ids are "<first 8 of the device uid>:<temp or channel name>", spaces as "_"
# ("GPU Temp" → "GPU_Temp") so a list of them can be space-separated. hwmon indices
# move between boots; CoolerControl's uids do not, and 8 hex chars are plenty
# to tell one machine's devices apart.
#
# Both row builders join /devices (what exists, with labels) to /status (the
# latest reading) in one jq pass.
_join() { jq -rs "$1" <(printf '%s' "$DEVICES") <(printf '%s' "$STATUS"); }

# id  device_uid  temp_name  device  label  degC
_sensor_rows() {
    _join '
        .[0] as $dev | .[1] as $st
        | $dev.devices[] | . as $d
        | ([$st.devices[]? | select(.uid == $d.uid)][0].status_history[-1].temps // []) as $now
        | ($d.info.temps // {}) | to_entries[] | .key as $k
        | ([$now[] | select(.name == $k) | .temp][0]) as $t
        | [ ($d.uid[0:8] + ":" + ($k | gsub(" "; "_"))), $d.uid, $k, $d.name, (.value.label // $k),
            (if $t == null then "-" else ($t | round | tostring) end) ] | @tsv' 2>/dev/null
}

# id  device_uid  channel  device  label  rpm  duty — anything with
# speed_options, i.e. a channel CoolerControl can drive.
_channel_rows() {
    _join '
        .[0] as $dev | .[1] as $st
        | $dev.devices[] | . as $d
        | ([$st.devices[]? | select(.uid == $d.uid)][0].status_history[-1].channels // []) as $now
        | ($d.info.channels // {}) | to_entries[] | select(.value.speed_options != null) | .key as $k
        | ([$now[] | select(.name == $k)][0] // {}) as $c
        | [ ($d.uid[0:8] + ":" + ($k | gsub(" "; "_"))), $d.uid, $k, $d.name, (.value.label // $k),
            (if $c.rpm == null then "-" else ($c.rpm | tostring) end),
            (if $c.duty == null then "-" else ($c.duty | round | tostring) end) ] | @tsv' 2>/dev/null
}

# Channel specs are "ID" or "ID@N"; a pin spec must have the @N.
_spec_id() { printf '%s' "${1%@*}"; }
_spec_n()  { if [[ "$1" == *@* ]]; then printf '%s' "${1##*@}"; fi; }
_check_spec() {  # SPEC NEED_N
    [[ "$1" =~ ^[^@[:space:]]+(@([0-9]{1,3}))?$ ]] || return 1
    local n="${BASH_REMATCH[2]}"
    if [[ -z "$n" ]]; then [[ "$2" != 1 ]]; return; fi
    (( 10#$n >= 1 && 10#$n <= 100 ))
}

# The profile set a floor uses: "carbonite" for none, "carbonite-m45" for 45%.
_set_uid() { if [[ -z "$1" || "$1" == 0 ]]; then printf '%s' "$TOP_UID"; else printf '%s-m%s' "$TOP_UID" "$1"; fi; }

_in_pins()  { [[ " ${PINS} " == *" $1@"* ]]; }
_pins_drop() {
    local id="$1" s out=""
    for s in $PINS; do [[ "${s%@*}" == "$id" ]] || out+="$s "; done
    PINS="${out% }"
}
_pins_set() { _pins_drop "$1"; PINS="$(echo "$PINS $1@$2" | xargs)"; }

# What controls each channel, from CoolerControl's own settings (so it reflects
# the GUI too): CONTROL[id] = curve | curve:N | pin:N | fixed:N.
declare -A CONTROL=()
_load_managed() {
    CONTROL=()
    local duid ch kind val id
    while IFS= read -r duid; do
        _api GET "/devices/${duid}/settings" || continue
        while IFS=$'\t' read -r ch kind val; do
            [[ -n "$ch" ]] || continue
            id="${duid:0:8}:${ch// /_}"
            case "$kind" in
                profile)
                    if [[ "$val" =~ ^${TOP_UID}-m([0-9]+)$ ]]; then CONTROL[$id]="curve:${BASH_REMATCH[1]}"
                    else CONTROL[$id]="curve"; fi ;;
                fixed)
                    if _in_pins "$id"; then CONTROL[$id]="pin:${val}"; else CONTROL[$id]="fixed:${val}"; fi ;;
            esac
        done < <(jq -r --arg p "$TOP_UID" '.settings[]?
                    | if ((.profile_uid // "") | startswith($p)) then [.channel_name, "profile", .profile_uid]
                      elif .speed_fixed != null then [.channel_name, "fixed", (.speed_fixed | tostring)]
                      else empty end | @tsv' <<<"$API_BODY")
    done < <(jq -r '.devices[] | select([.info.channels // {} | .[] | .speed_options] | any(. != null)) | .uid' <<<"$DEVICES")
}

# The curve channels as specs ("id" / "id@N") and the pins, both sorted.
_curve_specs() {
    local id c
    for id in "${!CONTROL[@]}"; do
        c="${CONTROL[$id]}"
        case "$c" in curve) echo "$id" ;; curve:*) echo "${id}@${c#curve:}" ;; esac
    done | sort | xargs
}
_pin_specs() {
    local id c
    for id in "${!CONTROL[@]}"; do
        c="${CONTROL[$id]}"; [[ "$c" == pin:* ]] && echo "${id}@${c#pin:}"
    done | sort | xargs
}

# Resolve the applied curve and sensors from the base profile set.
APPLIED=0; APPLIED_CURVE=""; APPLIED_SENSORS=""; APPLIED_HYST=""; APPLIED_DELAY=""
_load_applied() {
    APPLIED=0; APPLIED_CURVE=""; APPLIED_SENSORS=""; APPLIED_HYST=""; APPLIED_DELAY=""
    local top graphs
    top="$(jq -c --arg u "$TOP_UID" '.profiles[] | select(.uid == $u)' <<<"$PROFILES")"
    [[ -n "$top" ]] || return 0
    APPLIED=1
    if [[ "$(jq -r '.p_type' <<<"$top")" == "Mix" ]]; then
        graphs="$(jq -c --argjson m "$(jq -c '.member_profile_uids' <<<"$top")" \
                    '[.profiles[] | select(.uid as $u | $m | index($u))]' <<<"$PROFILES")"
    else
        graphs="[${top}]"
    fi
    APPLIED_CURVE="$(jq -r '.[0].speed_profile // [] | map("\(.[0] | floor):\(.[1])") | join(" ")' <<<"$graphs")"
    APPLIED_SENSORS="$(jq -r '[.[] | .temp_source | select(. != null) | (.device_uid[0:8] + ":" + (.temp_name | gsub(" "; "_")))] | join(" ")' <<<"$graphs")"
    if _api GET /functions; then
        APPLIED_HYST="$(jq -r --arg u "$FN_UID" '.functions[] | select(.uid == $u) | .deviance // empty | floor' <<<"$API_BODY")"
        APPLIED_DELAY="$(jq -r --arg u "$FN_UID" '.functions[] | select(.uid == $u) | .response_delay // empty' <<<"$API_BODY")"
    fi
}

# The default sensors, from what this host actually has: the CPU package sensor
# and the GPU's core temperature. There is deliberately no default for fans.
_default_sensors() {
    local rows; rows="$(_sensor_rows)"
    local cpu gpu
    cpu="$(awk -F'\t' 'tolower($5) ~ /package|tctl|tdie/ {print $1; exit}' <<<"$rows")"
    gpu="$(awk -F'\t' '$5 == "GPU Temp" {print $1; exit}' <<<"$rows")"
    printf '%s' "$(echo "$cpu $gpu" | xargs)"
}

# _resolve KIND ID — echoes "device_uid<TAB>name" for a sensor/channel id.
_resolve() {
    local kind="$1" id="$2" rows
    if [[ "$kind" == sensor ]]; then rows="$(_sensor_rows)"; else rows="$(_channel_rows)"; fi
    awk -F'\t' -v id="$id" '$1 == id { print $2 "\t" $3; exit }' <<<"$rows"
}

# _uri TEXT — TEXT percent-encoded for one URL path segment.
_uri() { jq -rn --arg s "$1" '$s | @uri'; }

# _channel_put ID ROUTE JSON — a write to one channel's settings.
_channel_put() {
    local r; r="$(_resolve channel "$1")"
    [[ -n "$r" ]] || { API_BODY='{"error":"no such channel on this host"}'; API_CODE=404; return 1; }
    # Percent-encoded: a channel name is the daemon's, and a space or a "/"
    # in it would break the URL or route the write somewhere else.
    _api PUT "/devices/$(_uri "${r%%$'\t'*}")/settings/$(_uri "${r#*$'\t'}")/$2" "$3"
}

# -----------------------------------------------------------------------------
# Writing. Create-or-update by fixed uid, so a second apply replaces the first
# instead of piling up "carbonite (2)" profiles.
# -----------------------------------------------------------------------------
_upsert() {
    local kind="$1" uid="$2" json="$3" list
    _api GET "/${kind}" || return 1
    list="$API_BODY"
    if jq -e --arg u "$uid" ".${kind}[] | select(.uid == \$u)" <<<"$list" >/dev/null; then
        _api PUT "/${kind}" "$json"
    else
        _api POST "/${kind}" "$json"
    fi
}

_function_json() {
    jq -nc --arg uid "$FN_UID" --argjson hyst "$1" --argjson delay "$2" '{
        uid: $uid, name: "Carbonite smoothing", f_type: "Standard",
        duty_minimum: 2, duty_maximum: 100,
        step_size_min_decreasing: 0, step_size_max_decreasing: 0,
        response_delay: $delay, deviance: $hyst, only_downward: true,
        sample_window: null, threshold_hopping: true, bypass_min_at_extremes: false }'
}

_graph_json() {  # uid name device_uid temp_name curve_json
    jq -nc --arg uid "$1" --arg name "$2" --arg du "$3" --arg tn "$4" --argjson sp "$5" --arg fn "$FN_UID" '{
        uid: $uid, p_type: "Graph", name: $name, speed_fixed: null, speed_profile: $sp,
        temp_source: { temp_name: $tn, device_uid: $du }, temp_min: null, temp_max: null,
        function_uid: $fn, member_profile_uids: [], mix_function_type: null, offset_profile: null }'
}

_mix_json() {  # uid name members_json
    jq -nc --arg uid "$1" --arg name "$2" --argjson m "$3" '{
        uid: $uid, p_type: "Mix", name: $name, speed_fixed: null, speed_profile: null,
        temp_source: null, temp_min: null, temp_max: null, function_uid: "0",
        member_profile_uids: $m, mix_function_type: "Max", offset_profile: null }'
}

# The curve with every duty raised to at least FLOOR.
_floored_json() {
    local floor="${1:-0}" i d out="["
    for (( i = 0; i < ${#CT[@]}; i++ )); do
        d="${CD[i]}"; (( d < floor )) && d="$floor"
        out+="[${CT[i]},${d}],"
    done
    printf '%s]' "${out%,}"
}

# _write_profiles CURVE "SENSOR_IDS" HYST DELAY "FLOORS" — the base set plus
# one set per floor. Echoes nothing; KEPT lists every uid written.
KEPT=()
_write_profiles() {
    local curve="$1" sensors="$2" hyst="$3" delay="$4" floors="$5"
    parse_curve "$curve" || return 1
    KEPT=("$FN_UID")

    local -a sids=() dus=() tns=()
    local id r
    for id in $sensors; do
        r="$(_resolve sensor "$id")"
        [[ -n "$r" ]] || { error "no sensor '${id}' on this host — see 'carbonite.sh sensors'"; return 1; }
        sids+=("$id"); dus+=("${r%%$'\t'*}"); tns+=("${r#*$'\t'}")
    done
    (( ${#sids[@]} )) || { error "no sensors to watch"; return 1; }

    _upsert functions "$FN_UID" "$(_function_json "$hyst" "$delay")" \
        || { error "could not write the function: $(_api_err)"; return 1; }

    local floor top name sp i g members
    for floor in 0 $floors; do
        top="$(_set_uid "$floor")"
        name="Carbonite"; (( floor )) && name="Carbonite >=${floor}%"
        sp="$(_floored_json "$floor")"
        KEPT+=("$top")
        if (( ${#sids[@]} == 1 )); then
            _upsert profiles "$top" "$(_graph_json "$top" "$name" "${dus[0]}" "${tns[0]}" "$sp")" \
                || { error "could not write ${top}: $(_api_err)"; return 1; }
        else
            members="["
            for (( i = 0; i < ${#sids[@]}; i++ )); do
                g="${top}-g-$((i + 1))"
                _upsert profiles "$g" "$(_graph_json "$g" "${name} ${sids[i]}" "${dus[i]}" "${tns[i]}" "$sp")" \
                    || { error "could not write ${g}: $(_api_err)"; return 1; }
                members+="\"${g}\","; KEPT+=("$g")
            done
            _upsert profiles "$top" "$(_mix_json "$top" "$name" "${members%,}]")" \
                || { error "could not write ${top}: $(_api_err)"; return 1; }
        fi
    done
    return 0
}

# Delete every carbonite profile not in KEPT. Called only once no channel
# points at them any more. Mixes go before their members.
_prune() {
    local keep=" ${KEPT[*]} " uid
    _load_profiles
    while IFS= read -r uid; do
        [[ "$keep" == *" $uid "* ]] && continue
        _api DELETE "/profiles/${uid}" || warn "could not delete ${uid}: $(_api_err)"
    done < <(jq -r --arg p "$TOP_UID" '.profiles | map(select(.uid | startswith($p)))
                | sort_by(if .p_type == "Mix" then 0 else 1 end) | .[].uid' <<<"$PROFILES")
}

# -----------------------------------------------------------------------------
# Commands
# -----------------------------------------------------------------------------
# login takes the token, in this order, from: --token (deprecated, warned in
# main), stdin when it is not a terminal (`printf '%s\n' "$tok" | carbonite.sh
# login`), $CARB_TOKEN, or a hidden prompt on a terminal. Never from the file:
# login is how the file's token is replaced.
cmd_login() {
    local tok=""
    if [[ "$TOKEN_SOURCE" == flag ]]; then
        tok="$TOKEN"
    elif [[ ! -t 0 ]]; then
        IFS= read -r tok || true
    fi
    if [[ -z "$tok" && -n "${CARB_TOKEN:-}" ]]; then
        tok="$CARB_TOKEN"
    elif [[ -z "$tok" && -t 0 ]]; then
        read -r -s -p "CoolerControl access token (with write access): " tok; echo >&2
    fi
    tok="${tok%$'\r'}"
    [[ -n "$tok" ]] || error_exit "login reads the token from stdin: printf '%s\n' cc_… | carbonite.sh login (or run it on a terminal and paste it)"
    _valid_token "$tok" || error_exit "that token has spaces or control characters — paste just the token"
    TOKEN="$tok"
    _api GET /handshake || error_exit "CoolerControl is not answering at ${URL}"
    _api GET /devices || error_exit "CoolerControl refused that token: $(_api_err)"
    FILE_TOKEN="$TOKEN"
    _write_conf
    success "token saved to ${CONF_FILE} (mode 600)"
}

cmd_check() {
    _need_api
    success "CoolerControl at ${URL} accepts the token (${TOKEN_SOURCE})"
}

cmd_sensors() {
    _need_api; _load_status; _load_profiles; _load_applied
    local watch=" ${APPLIED_SENSORS} " id duid dname label t
    while IFS=$'\t' read -r id duid _ dname label t; do
        [[ -n "$id" ]] || continue
        printf '%s\t%s\t%s\t%s\t%d\n' "$id" "$dname" "$label" "$t" "$([[ "$watch" == *" $id "* ]] && echo 1 || echo 0)"
    done < <(_sensor_rows)
}

cmd_channels() {
    _need_api; _load_status; _load_managed
    local id duid ch dname label rpm duty
    while IFS=$'\t' read -r id duid ch dname label rpm duty; do
        [[ -n "$id" ]] || continue
        printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$id" "$dname" "$label" "$rpm" "$duty" "${CONTROL[$id]:--}"
    done < <(_channel_rows)
}

cmd_curve() {
    _need_api; _load_profiles; _load_applied
    (( APPLIED )) || error_exit "nothing applied yet — see 'carbonite.sh apply'"
    parse_curve "$APPLIED_CURVE" || exit 1
    local i; for (( i = 0; i < ${#CT[@]}; i++ )); do printf '%s\t%s\n' "${CT[i]}" "${CD[i]}"; done
}

cmd_simulate() {
    parse_curve "${CURVE:-$DEFAULT_CURVE}" || exit 1
    local stop; stop="$(_stop_below)"
    [[ -z "$stop" ]] || warn "this curve is at 0% up to ${stop}C: fans on it stop there unless given a floor (ID@N); apply refuses it without one, or --allow-stop"
    (( $# )) || set -- 30 40 50 60 70 80 90
    local t
    for t in "$@"; do
        [[ "$t" =~ ^[0-9]{1,3}$ ]] || error_exit "not a temperature: ${t}"
        printf '%-4s %s%%\n' "$t" "$(duty_at "$t")"
    done
}

# _do_pins "ID@N ..." — fixed duty first, then remembered as ours.
_do_pins() {
    local s id n fails=0
    for s in $1; do
        id="$(_spec_id "$s")"; n="$(_spec_n "$s")"
        if _channel_put "$id" manual "{\"speed_fixed\":${n}}"; then
            _pins_set "$id" "$n"; success "${id} pinned at ${n}%"
        else
            error "${id}: could not pin: $(_api_err)"; fails=$((fails + 1))
        fi
    done
    _write_conf
    (( fails == 0 ))
}

cmd_pin() {
    (( $# )) || error_exit "pin needs ID@N (e.g. 7bfee7e1:fan1@100)"
    local s
    for s in "$@"; do _check_spec "$s" 1 || error_exit "bad pin '${s}' — want ID@N, N 1-100"; done
    _need_api
    for s in "$@"; do [[ -n "$(_resolve channel "$(_spec_id "$s")")" ]] || error_exit "no fan channel '$(_spec_id "$s")' — see 'channels'"; done
    _do_pins "$*" || exit 1
}

cmd_unpin() {
    (( $# )) || error_exit "unpin needs channel ids"
    _need_api
    local id fails=0
    for id in "$@"; do
        id="$(_spec_id "$id")"
        _in_pins "$id" || { warn "${id} is not a carbonite pin — left alone"; continue; }
        if (( ! YES )); then
            [[ -t 0 ]] || error_exit "unpin can stop a pump — pass --yes"
            local a; read -r -p "Hand ${id} back to the board? If it is a pump, the board decides its speed. [y/N] " a
            [[ "$a" == [yY]* ]] || { info "${id} stays pinned"; continue; }
        fi
        if _channel_put "$id" profile "{\"profile_uid\":\"${DEFAULT_PROFILE_UID}\"}"; then
            _pins_drop "$id"; success "${id} → board control"
        else
            error "${id}: $(_api_err)"; fails=$((fails + 1))
        fi
    done
    _write_conf
    (( fails == 0 )) || exit 1
}

cmd_apply() {
    _need_api; _load_status
    local curve="${CURVE:-$DEFAULT_CURVE}" sensors="${SENSORS:-}" channels="${CHANNELS:-}" pins="${PIN:-}"
    parse_curve "$curve" || exit 1
    [[ -n "$sensors" ]]  || sensors="$(_default_sensors)"
    [[ -n "$sensors" ]]  || error_exit "no CPU/GPU sensor found to default to — pass --sensors (see 'sensors')"
    # No default: a pump's header cannot be told from its label, and a pump on
    # a curve that drops to 25% is worse than any noise.
    [[ -n "$channels" ]] || error_exit "apply needs --channels — the fans to put on the curve (see 'channels'). Pin a pump with --pin ID@100."

    # Everything is checked before anything is written: a typo must not leave
    # half the fans on the new curve.
    local s id floors="" seen=" "
    for s in $pins; do
        _check_spec "$s" 1 || error_exit "bad pin '${s}' — want ID@N, N 1-100"
        id="$(_spec_id "$s")"
        [[ -n "$(_resolve channel "$id")" ]] || error_exit "no fan channel '${id}' on this host — see 'carbonite.sh channels'"
        seen+="${id} "
    done
    for s in $channels; do
        _check_spec "$s" 0 || error_exit "bad channel '${s}' — want ID or ID@N, N 1-100"
        id="$(_spec_id "$s")"
        [[ -n "$(_resolve channel "$id")" ]] || error_exit "no fan channel '${id}' on this host — see 'carbonite.sh channels'"
        [[ "$seen" == *" ${id} "* ]] && error_exit "${id} is listed twice (curve and pin?)"
        seen+="${id} "
        [[ -n "$(_spec_n "$s")" ]] && floors+="$(_spec_n "$s") "
    done
    floors="$(printf '%s\n' $floors | sort -un | xargs)"
    _refuse_stopping_fans "$channels"

    # Pins first: if anything below fails, a pump is already safe.
    if [[ -n "$pins" ]]; then _do_pins "$pins" || error_exit "a pin failed — the curve was not touched"; fi

    _load_managed
    local before; before="$(_curve_specs)"

    local hyst="${HYST:-3}" delay="${DELAY:-3}"
    info "curve ${curve} · sensors ${sensors} · hysteresis ${hyst}C · delay ${delay}s${floors:+ · floors ${floors// /% }%}"
    _write_profiles "$curve" "$sensors" "$hyst" "$delay" "$floors" || exit 1

    local fails=0 n
    for s in $channels; do
        id="$(_spec_id "$s")"; n="$(_spec_n "$s")"
        if _channel_put "$id" profile "{\"profile_uid\":\"$(_set_uid "$n")\"}"; then
            # A channel moved from a pin to the curve is no longer a pin.
            _in_pins "$id" && { _pins_drop "$id"; _write_conf; }
            success "${id} → curve${n:+ (never below ${n}%)}"
        else
            error "${id}: $(_api_err)"; fails=$((fails + 1))
        fi
    done

    # --channels is the whole list: a fan that was on the curve and is not any
    # more goes back to the board, and only then are unused profiles deleted.
    for s in $before; do
        id="$(_spec_id "$s")"
        [[ "$seen" == *" ${id} "* ]] && continue
        if _channel_put "$id" profile "{\"profile_uid\":\"${DEFAULT_PROFILE_UID}\"}"; then
            info "${id} → board control (no longer listed)"
        else
            error "${id}: could not hand back: $(_api_err)"; fails=$((fails + 1))
        fi
    done
    (( fails == 0 )) && _prune
    _warn_conflicts
    (( fails == 0 )) || exit 1
}

cmd_set_curve() {
    local curve="${1:-${CURVE:-}}"
    [[ -n "$curve" ]] || error_exit "set-curve needs POINTS"
    # Validated before anything is touched.
    parse_curve "$curve" || exit 1
    _need_api; _load_status; _load_profiles; _load_applied; _load_managed
    (( APPLIED )) || error_exit "nothing applied yet — use 'apply' first"
    _refuse_stopping_fans "$(_curve_specs)"
    local floors s
    floors="$(for s in $(_curve_specs); do _spec_n "$s"; echo; done | grep . | sort -un | xargs)"
    _write_profiles "$curve" "$APPLIED_SENSORS" "${APPLIED_HYST:-3}" "${APPLIED_DELAY:-3}" "$floors" || exit 1
    success "curve is now ${curve}"
}

cmd_release() {
    _need_api; _load_managed
    local specs; specs="$(_curve_specs)"
    if (( ! YES )); then
        [[ -t 0 ]] || error_exit "release changes the fans — pass --yes"
        local a; read -r -p "Hand ${specs:-no channels} back to the board and delete the carbonite profiles? [y/N] " a
        [[ "$a" == [yY]* ]] || { info "nothing changed"; return 0; }
    fi
    local s id fails=0
    for s in $specs; do
        id="$(_spec_id "$s")"
        # The built-in Default Profile is CoolerControl's "give it back": hwmon
        # channels return to the pwm_enable mode they had before.
        if _channel_put "$id" profile "{\"profile_uid\":\"${DEFAULT_PROFILE_UID}\"}"; then
            success "${id} → board control"
        else
            error "${id}: $(_api_err)"; fails=$((fails + 1))
        fi
    done
    (( fails == 0 )) || error_exit "some channels still use a carbonite profile — not deleting them"

    KEPT=(); _prune
    _api DELETE "/functions/${FN_UID}" &>/dev/null
    success "carbonite profiles removed"
    local p; p="$(_pin_specs)"
    [[ -z "$p" ]] || info "pins kept: ${p} — 'unpin' them by name if you mean it"
}

_conflicting_units() {
    local u st
    for u in "${CONFLICT_UNITS[@]}"; do
        if "$SYSTEMCTL" is-active --quiet "$u" 2>/dev/null; then st="active"
        elif "$SYSTEMCTL" is-enabled --quiet "$u" 2>/dev/null; then st="enabled at boot"
        else continue; fi
        printf '%s\t%s\n' "$u" "$st"
    done
}
cmd_conflicts() { _conflicting_units; }

_warn_conflicts() {
    local out; out="$(_conflicting_units)"
    [[ -n "$out" ]] || return 0
    warn "these also write pwm and will fight CoolerControl:"
    local u st; while IFS=$'\t' read -r u st; do warn "  ${u}  [${st}]"; done <<<"$out"
    warn "  stop one with: sudo systemctl disable --now <unit>"
}

cmd_config() {
    printf 'url=%s\n' "$URL"
    printf 'config=%s\n' "$CONF_FILE"
    printf 'token=%s\n' "$([[ -n "$TOKEN" ]] && echo set || echo none)"
    printf 'token_source=%s\n' "$TOKEN_SOURCE"
    printf 'default_curve=%s\n' "$DEFAULT_CURVE"
    local reach=0 auth=0
    if command -v jq &>/dev/null && _api GET /handshake; then
        reach=1
        if [[ -n "$TOKEN" ]] && _api GET /devices; then
            auth=1; DEVICES="$API_BODY"
        fi
    fi
    printf 'reachable=%d\nauthorized=%d\n' "$reach" "$auth"
    if (( auth )); then
        _load_profiles; _load_applied; _load_managed
        printf 'applied=%d\n' "$APPLIED"
        printf 'curve=%s\n' "$APPLIED_CURVE"
        printf 'sensors=%s\n' "$APPLIED_SENSORS"
        printf 'hyst=%s\n' "$APPLIED_HYST"
        printf 'delay=%s\n' "$APPLIED_DELAY"
        printf 'channels=%s\n' "$(_curve_specs)"
        printf 'pins=%s\n' "$(_pin_specs)"
    else
        printf 'applied=0\n'
    fi
    printf 'conflicts=%d\n' "$(_conflicting_units | grep -c . || true)"
}

cmd_status() {
    _need_api; _load_status; _load_profiles; _load_applied; _load_managed
    if (( APPLIED )); then
        printf 'curve   : %s   (hysteresis %sC, delay %ss, down only)\n' "$APPLIED_CURVE" "${APPLIED_HYST:--}" "${APPLIED_DELAY:--}"
        printf 'sensors : %s\n' "$APPLIED_SENSORS"
    else
        printf 'curve   : none applied — the board (or the GUI) is in charge\n'
    fi
    local watch=" ${APPLIED_SENSORS} " id duid dname label t
    printf '\ntemps\n'
    while IFS=$'\t' read -r id duid _ dname label t; do
        [[ " $watch " == *" $id "* ]] || continue
        printf '  %-20s %-28s %4sC\n' "$id" "$label" "$t"
    done < <(_sensor_rows)
    printf '\nfans\n'
    local ch rpm duty c
    while IFS=$'\t' read -r id duid ch dname label rpm duty; do
        c="${CONTROL[$id]:--}"
        case "$c" in
            curve:*) c="curve, never below ${c#curve:}%" ;;
            pin:*)   c="pinned at ${c#pin:}%" ;;
            fixed:*) c="fixed ${c#fixed:}% (not carbonite)" ;;
        esac
        printf '  %-20s %-16s %6s rpm %5s%%  %s\n' "$id" "$label" "$rpm" "$duty" "$c"
    done < <(_channel_rows)
    local c2; c2="$(_conflicting_units)"
    [[ -z "$c2" ]] || { printf '\nconflict: these also write pwm:\n'; sed 's/^/  /' <<<"$c2"; }
}

# -----------------------------------------------------------------------------
main() {
    local cmd="${1:-}"; shift 2>/dev/null || true
    local -a rest=()
    local token_flag="" url_flag=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --curve)    [[ $# -ge 2 ]] || error_exit "--curve needs POINTS";  CURVE="$2"; shift 2 ;;
            --curve=*)  CURVE="${1#*=}"; shift ;;
            --sensors)  [[ $# -ge 2 ]] || error_exit "--sensors needs IDs";   SENSORS="$2"; shift 2 ;;
            --sensors=*) SENSORS="${1#*=}"; shift ;;
            --channels) [[ $# -ge 2 ]] || error_exit "--channels needs IDs";  CHANNELS="$2"; shift 2 ;;
            --channels=*) CHANNELS="${1#*=}"; shift ;;
            --pin)      [[ $# -ge 2 ]] || error_exit "--pin needs ID@N";      PIN="$2"; shift 2 ;;
            --pin=*)    PIN="${1#*=}"; shift ;;
            --hyst)     [[ "${2:-}" =~ ^[0-9]{1,2}$ ]] || error_exit "--hyst needs degrees (0-99)"; HYST="$2"; shift 2 ;;
            --delay)    [[ "${2:-}" =~ ^[0-9]{1,2}$ ]] || error_exit "--delay needs seconds (0-99)"; DELAY="$2"; shift 2 ;;
            --url)      [[ $# -ge 2 ]] || error_exit "--url needs URL";       url_flag="$2"; shift 2 ;;
            --token)    [[ $# -ge 2 ]] || error_exit "--token needs TOKEN";   token_flag="$2"; shift 2 ;;
            --yes|-y)   YES=1; shift ;;
            --allow-stop) ALLOW_STOP=1; shift ;;
            -h|--help)  usage; exit 0 ;;
            --)         shift; rest+=("$@"); break ;;
            -*)         error_exit "unknown flag: $1 (see --help)" ;;
            *)          rest+=("$1"); shift ;;
        esac
    done

    _read_conf
    [[ -n "$url_flag" ]] && URL="${url_flag%/}"
    if [[ -n "$token_flag" ]]; then
        # Kept so existing scripts still work, but said: argv is public.
        warn "--token puts the token on this process's command line, where 'ps' shows it to every user. Pipe it to 'carbonite.sh login' instead, or set \$CARB_TOKEN."
        TOKEN="$token_flag"; TOKEN_SOURCE="flag"
    fi
    # A newline in it would be a second header in curl's config.
    [[ -z "$TOKEN" ]] || _valid_token "$TOKEN" || error_exit "the access token (${TOKEN_SOURCE}) has spaces or control characters"

    case "$cmd" in
        login)        cmd_login ;;
        check)        cmd_check ;;
        status)       cmd_status ;;
        sensors)      cmd_sensors ;;
        channels)     cmd_channels ;;
        curve)        cmd_curve ;;
        simulate)     cmd_simulate "${rest[@]}" ;;
        apply)        cmd_apply ;;
        set-curve)    cmd_set_curve "${rest[@]}" ;;
        pin)          cmd_pin "${rest[@]}" ;;
        unpin)        cmd_unpin "${rest[@]}" ;;
        release)      cmd_release ;;
        conflicts)    cmd_conflicts ;;
        config)       cmd_config ;;
        version)      echo "carbonite.sh ${VERSION}" ;;
        ""|help)      usage ;;
        *)            error_exit "unknown command: ${cmd} (see --help)" ;;
    esac
}

main "$@"
