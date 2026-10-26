#!/usr/bin/env bash
# The carbonite engine against a fake, stateful CoolerControl (fake-coolercontrol,
# standing in for curl). No daemon, no token, no hardware.
#
# The machine in the fixture is the one carbonite was written for: an MSI board
# whose NCT6687 has the AIO pump on "CPU Fan" (fan1) and the radiator fans on
# "Pump Fan" (fan2) — labels that lie, which is why nothing is chosen by label —
# plus case fans; a CPU with a package sensor; and an NVIDIA GPU whose
# temperature is called "GPU Temp", with a space in it, which broke ids once.
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE="${TEST_DIR}/../carbonite.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
export FAKE_CC="$T/cc" CARB_CURL="${TEST_DIR}/fake-coolercontrol"
export CARB_CONFIG_DIR="$T/conf" CARB_URL="http://cc.test:11987" CARB_TOKEN="tok"
export CARB_SYSTEMCTL="$T/systemctl"
printf '#!/usr/bin/env bash\nexit 1\n' > "$CARB_SYSTEMCTL"; chmod +x "$CARB_SYSTEMCTL"

# shellcheck source=fixture.sh
source "${TEST_DIR}/fixture.sh"

FAILS=0
check() { local d="$1"; shift; if "$@"; then echo "   ok   - $d"; else echo "   FAIL - $d"; FAILS=$((FAILS + 1)); fi; }
has()   { case "$2" in *"$1"*) return 0 ;; *) return 1 ;; esac; }
eng()   { OUT="$(bash "$ENGINE" "$@" 2>&1)"; RC=$?; }
# eng_in INPUT ARGS... — eng with INPUT on stdin.
eng_in() { local in="$1"; shift; OUT="$(printf '%s' "$in" | bash "$ENGINE" "$@" 2>&1)"; RC=$?; }
# setting DEVICE_UID CHANNEL FIELD — one field of a channel's stored setting.
setting() { jq -r --arg c "$2" ".settings[] | select(.channel_name == \$c) | .$3 // \"null\"" "$FAKE_CC/settings-$1.json" 2>/dev/null; }
is()      { [[ "$1" == "$2" ]]; }
prof()    { jq -c --arg u "$1" ".profiles[] | select(.uid == \$u) | $2" "$FAKE_CC/profiles.json"; }
nprof()   { jq '[.profiles[] | select(.uid | startswith("carbonite"))] | length' "$FAKE_CC/profiles.json"; }

echo "## 1. simulate is CoolerControl's interpolation, and touches nothing"
reset_cc
eng simulate --curve "30:25 50:35 65:55 75:75 85:100" -- 20 57 80 95
check "below the first point holds the first duty" has "20   25%" "$OUT"
check "linear between points (57C → 44%)"           has "57   44%" "$OUT"
check "rounds half up like the daemon (80C → 88%)"  has "80   88%" "$OUT"
check "above the last point holds the last duty"    has "95   100%" "$OUT"
check "no API call was made"                        bash -c "[[ ! -s '$FAKE_CC/calls' ]]"

echo "## 2. bad curves and specs are refused before anything is written"
for c in "60:40 50:30" "70:100" "40:50 60:30" "40:150 60:160" "abc"; do
    eng simulate --curve "$c" 50
    check "rejects curve '${c}'" bash -c "(( $RC != 0 ))"
done
reset_cc
for spec in "--channels ${NCT:0:8}:fan3@0" "--channels ${NCT:0:8}:fan3@101" "--channels a@b" \
            "--pin ${NCT:0:8}:fan1 --channels ${NCT:0:8}:fan3"; do
    # shellcheck disable=SC2086
    eng apply $spec
    check "rejects ${spec}" bash -c "(( $RC != 0 ))"
done
check "  and nothing was written"                   bash -c "! grep -qE '^(POST|PUT|DELETE) /(profiles|functions|devices)' '$FAKE_CC/calls'"

echo "## 3. ids carry no spaces; the TSV says what controls each fan"
reset_cc
eng sensors
check "the GPU sensor id is GPU_Temp"               has "${GPU:0:8}:GPU_Temp	" "$OUT"
check "  and its label keeps the space"             has "	GPU Temp	36	" "$OUT"
check "temperatures are rounded"                    has "43	0" "$OUT"
eng channels
check "a fan channel has rpm, duty and control"     has "${NCT:0:8}:fan1	nct6687	CPU Fan	1120	35	-" "$OUT"
check "a channel with no speed options is not"      bash -c '! grep -q "CPU Load" <<<"$OUT"'

echo "## 4. no fan is ever chosen for you"
reset_cc
eng apply
check "apply without --channels refuses"            bash -c "(( $RC != 0 ))"
check "  and says why"                              has "needs --channels" "$OUT"
check "  writing nothing"                           bash -c "! grep -qE '^(POST|PUT|DELETE) /(profiles|functions|devices)' '$FAKE_CC/calls'"

echo "## 5. the MSI layout: pump pinned, radiator fans with a floor, case fans free"
reset_cc
eng apply --curve "30:30 50:50 80:100" --pin "${NCT:0:8}:fan1@100" \
    --channels "${NCT:0:8}:fan2@45 ${NCT:0:8}:fan3"
check "apply succeeded"                             is "$RC" 0
check "the pump is pinned at 100%"                  is "$(setting "$NCT" fan1 speed_fixed)" 100
check "  with no profile"                           is "$(setting "$NCT" fan1 profile_uid)" null
check "  and the pin was written before any profile" bash -c "
    p=\$(grep -n '/fan1/manual' '$FAKE_CC/calls' | head -1 | cut -d: -f1)
    q=\$(grep -nE '^(POST|PUT) /profiles' '$FAKE_CC/calls' | head -1 | cut -d: -f1)
    [[ -n \"\$p\" && -n \"\$q\" && \$p -lt \$q ]]"
check "the radiator fans use the 45% set"           is "$(setting "$NCT" fan2 profile_uid)" carbonite-m45
check "the case fan uses the plain curve"           is "$(setting "$NCT" fan3 profile_uid)" carbonite
check "the floored graph never drops below 45"      is "$(prof carbonite-m45-g-1 .speed_profile)" "[[30,45],[50,50],[80,100]]"
check "the plain graph keeps the curve"             is "$(prof carbonite-g-1 .speed_profile)" "[[30,30],[50,50],[80,100]]"
check "two sensors make Mix profiles, taking max"   is "$(prof carbonite-m45 .mix_function_type)" '"Max"'
check "the GPU graph uses the real temp name"       is "$(prof carbonite-g-2 .temp_source.temp_name)" '"GPU Temp"'
check "the function is one-sided"                   bash -c "jq -e '.functions[] | select(.uid==\"carbonite-fn\") | .only_downward == true and .deviance == 3' '$FAKE_CC/functions.json' >/dev/null"
check "the pin is remembered as carbonite's"        grep -q "^pins=${NCT:0:8}:fan1@100$" "$CARB_CONFIG_DIR/config"
check "an env token is not written to the file"     grep -q '^token=$' "$CARB_CONFIG_DIR/config"

echo "## 6. what was applied is read back"
eng config
check "applied=1"                                   has "applied=1" "$OUT"
check "the curve"                                   has "curve=30:30 50:50 80:100" "$OUT"
check "the sensors, as ids"                         has "sensors=${CPU:0:8}:temp1 ${GPU:0:8}:GPU_Temp" "$OUT"
check "the channels, with their floors"             has "channels=${NCT:0:8}:fan2@45 ${NCT:0:8}:fan3" "$OUT"
check "the pins"                                    has "pins=${NCT:0:8}:fan1@100" "$OUT"
eng channels
check "control: pin"                                has "CPU Fan	1120	35	pin:100" "$OUT"
check "control: curve with a floor"                 has "Pump Fan	2850	100	curve:45" "$OUT"
check "control: curve"                              has "System Fan #1	3022	60	curve" "$OUT"
eng status
check "status names the pin"                        has "pinned at 100%" "$OUT"
check "  and the floor"                             has "never below 45%" "$OUT"

echo "## 7. a fixed speed set elsewhere is not a pin"
reset_cc
jq -n '{settings:[{channel_name:"fan7",profile_uid:null,speed_fixed:60}]}' > "$FAKE_CC/settings-$NCT.json"
eng channels
check "shown as fixed, not pin"                     has "System Fan #5	0	60	fixed:60" "$OUT"
eng unpin "${NCT:0:8}:fan7" --yes
check "unpin leaves it alone"                       is "$(setting "$NCT" fan7 speed_fixed)" 60
check "  and says so"                               has "not a carbonite pin" "$OUT"

echo "## 8. set-curve keeps sensors, channels and floors"
reset_cc
eng apply --curve "30:30 80:100" --pin "${NCT:0:8}:fan1@100" --channels "${NCT:0:8}:fan2@45 ${NCT:0:8}:fan3"
: > "$FAKE_CC/calls"
eng set-curve "35:25 60:60 85:100"
check "set-curve succeeded"                         is "$RC" 0
check "the plain curve changed"                     is "$(prof carbonite-g-1 .speed_profile)" "[[35,25],[60,60],[85,100]]"
check "the floored copy changed with it"            is "$(prof carbonite-m45-g-1 .speed_profile)" "[[35,45],[60,60],[85,100]]"
check "  on both sensors"                           is "$(prof carbonite-m45-g-2 .temp_source.temp_name)" '"GPU Temp"'
check "no channel was touched"                      bash -c "! grep -qE '/(profile|manual) ' '$FAKE_CC/calls'"
eng set-curve "80:50 70:40"
check "a bad curve is refused"                      bash -c "(( $RC != 0 ))"
check "  and the applied one is unchanged"          is "$(prof carbonite-g-1 .speed_profile)" "[[35,25],[60,60],[85,100]]"

echo "## 9. apply is the whole list: dropped fans go back, profiles are pruned"
eng apply --curve "30:30 80:100" --sensors "${CPU:0:8}:temp1" --channels "${NCT:0:8}:fan3"
check "apply succeeded"                             is "$RC" 0
check "the dropped radiator fans went to the board" is "$(setting "$NCT" fan2 profile_uid)" 0
check "the 45% set is gone"                         bash -c "! grep -q carbonite-m45 '$FAKE_CC/profiles.json'"
check "one sensor: a single Graph, no members"      is "$(nprof)" 1
check "the pin was not touched"                     is "$(setting "$NCT" fan1 speed_fixed)" 100

echo "## 10. moving a fan between pin and curve is explicit"
eng apply --curve "30:30 80:100" --channels "${NCT:0:8}:fan1 ${NCT:0:8}:fan3"
check "a pinned fan listed in --channels joins the curve" is "$(setting "$NCT" fan1 profile_uid)" carbonite
check "  and stops being a pin"                     bash -c "! grep -q 'fan1@' '$CARB_CONFIG_DIR/config'"
eng pin "${NCT:0:8}:fan1@100"
check "pin moves it off the curve"                  is "$(setting "$NCT" fan1 speed_fixed)" 100
check "pin without a duty is refused"               bash -c "! bash '$ENGINE' pin '${NCT:0:8}:fan3' &>/dev/null"

echo "## 11. a wrong channel writes nothing"
reset_cc
eng apply --pin "${NCT:0:8}:fan1@100" --channels "${NCT:0:8}:fan3 ${NCT:0:8}:fan9"
check "apply fails"                                 bash -c "(( $RC != 0 ))"
check "  naming the channel"                        has "fan9" "$OUT"
check "  before anything was written, pins included" bash -c "! grep -qE '^(POST|PUT|DELETE) /(profiles|functions|devices)' '$FAKE_CC/calls'"

echo "## 12. release hands back the curve, keeps pins"
reset_cc
eng apply --pin "${NCT:0:8}:fan1@100" --channels "${NCT:0:8}:fan2@45 ${NCT:0:8}:fan3"
eng release --yes
check "release succeeded"                           is "$RC" 0
check "curve fans go to the Default profile"        is "$(setting "$NCT" fan3 profile_uid)" 0
check "  floored ones too"                          is "$(setting "$NCT" fan2 profile_uid)" 0
check "no carbonite profile is left"                bash -c "! grep -q carbonite '$FAKE_CC/profiles.json'"
check "  nor the function"                          bash -c "! grep -q carbonite '$FAKE_CC/functions.json'"
check "the pump stays pinned"                       is "$(setting "$NCT" fan1 speed_fixed)" 100
check "  and that is said"                          has "pins kept" "$OUT"
eng unpin "${NCT:0:8}:fan1" </dev/null
check "unpin without --yes and no terminal refuses" bash -c "(( $RC != 0 ))"
check "  leaving the pump pinned"                   is "$(setting "$NCT" fan1 speed_fixed)" 100
eng unpin "${NCT:0:8}:fan1" --yes
check "unpin --yes hands it back"                   is "$(setting "$NCT" fan1 profile_uid)" 0
check "  and forgets it"                            bash -c "! grep -q 'fan1@' '$CARB_CONFIG_DIR/config'"
reset_cc; eng apply --channels "${NCT:0:8}:fan3"
eng release </dev/null
check "release without --yes and no terminal refuses" bash -c "(( $RC != 0 ))"
check "  and changed nothing"                       bash -c "grep -q carbonite '$FAKE_CC/profiles.json'"

echo "## 13. the daemon or the token missing is said plainly"
reset_cc; touch "$FAKE_CC/down"
eng status
check "a down daemon is named"                      has "not answering" "$OUT"
rm "$FAKE_CC/down"
CARB_TOKEN=wrong eng status
check "a refused token is named"                    has "refused the token" "$OUT"
touch "$FAKE_CC/readonly"
eng apply --channels "${NCT:0:8}:fan3"
check "a read-only token fails apply"               bash -c "(( $RC != 0 ))"
check "  with the daemon's reason"                  has "write access" "$OUT"
rm "$FAKE_CC/readonly"
CARB_TOKEN="" eng config
check "config works with no token"                  has "authorized=0" "$OUT"

echo "## 14. login reads the token from stdin, saves it privately, keeps the pins"
reset_cc; rm -rf "$CARB_CONFIG_DIR"
eng pin "${NCT:0:8}:fan1@100"
CARB_TOKEN="" eng_in $'tok\n' login
check "login succeeded"                             is "$RC" 0
check "  with the token from stdin"                 grep -q '^token=tok$' "$CARB_CONFIG_DIR/config"
# GNU stat -c, else BSD stat -f: the suite runs on a Mac too.
check "the file is mode 600"                        bash -c "[[ \$(stat -c %a '$CARB_CONFIG_DIR/config' 2>/dev/null || stat -f %Lp '$CARB_CONFIG_DIR/config') == 600 ]]"
check "the pin survived the login"                  grep -q 'fan1@100' "$CARB_CONFIG_DIR/config"
CARB_TOKEN="" eng check
check "the saved token is used"                     has "(file)" "$OUT"
CARB_TOKEN="" eng_in $'nope\n' login
check "a refused token is not saved"                bash -c "grep -q '^token=tok$' '$CARB_CONFIG_DIR/config'"
CARB_TOKEN="" eng login </dev/null
check "no token on stdin: refused"                  bash -c "(( $RC != 0 ))"
check "  saying how to give it"                     has "reads the token from stdin" "$OUT"
CARB_TOKEN="" eng_in $'cc_two words\n' login
check "a token with a space is refused"             bash -c "(( $RC != 0 ))"
rm -rf "$CARB_CONFIG_DIR"
CARB_TOKEN="" eng login --token tok </dev/null
check "the deprecated --token still logs in"        grep -q '^token=tok$' "$CARB_CONFIG_DIR/config"
check "  and warns that argv is public"             has "command line" "$OUT"
rm -rf "$CARB_CONFIG_DIR"
CARB_TOKEN=tok eng login </dev/null
check "login takes \$CARB_TOKEN"                   grep -q '^token=tok$' "$CARB_CONFIG_DIR/config"

echo "## 15. a curve at 0% stops fans: refused unless floored or --allow-stop"
F3="${NCT:0:8}:fan3" F7="${NCT:0:8}:fan7"
eng simulate --curve "30:0 85:100" 25
check "simulate warns that fans stop"               has "0% up to 30C" "$OUT"
check "  and still shows the curve"                 has "25   0%" "$OUT"
reset_cc; eng apply --curve "30:0 85:100" --channels "$F3 ${F7}@20"
check "apply refuses it"                            bash -c "(( $RC != 0 ))"
check "  naming the unfloored fan"                  has "STOPS ${F3}" "$OUT"
check "  not the floored one"                       bash -c "! grep -q 'fan7' <<<\"\$1\"" _ "$OUT"
check "  and writes nothing"                        bash -c "! grep -qE '^(POST|PUT|DELETE) /(profiles|functions|devices)' '$FAKE_CC/calls'"
reset_cc; eng apply --curve "30:0 85:100" --channels "${F3}@20 ${F7}@25"
check "every fan floored: applied"                  is "$RC" 0
reset_cc; eng apply --curve "30:0 85:100" --channels "$F3" --allow-stop
check "--allow-stop: applied as asked"              is "$RC" 0
reset_cc; eng apply --channels "$F3"; eng set-curve "40:0 85:100"
check "set-curve refuses it for the fans on the curve" bash -c "(( $RC != 0 )) && grep -q 'STOPS' <<<\"\$1\"" _ "$OUT"
eng set-curve "40:0 85:100" --allow-stop
check "  unless --allow-stop"                       is "$RC" 0
eng simulate --curve "30:25 85:100" 25
check "a curve that never reaches 0% warns nothing" bash -c "! grep -q 'warn' <<<\"\$1\"" _ "$OUT"

echo "## 16. a channel name is encoded in the URL"
reset_cc
jq --arg u "$NCT" '(.devices[] | select(.uid == $u) | .info.channels) += {"Pump Fan/2": {"label": "Pump", "speed_options": {"min_duty":0,"max_duty":100,"fixed_enabled":true,"extension":null}}}' \
    "$FAKE_CC/devices.json" > "$T/d.json" && mv "$T/d.json" "$FAKE_CC/devices.json"
eng apply --channels "${NCT:0:8}:Pump_Fan/2"
check "a space and a / in the name: applied"         is "$RC" 0
check "  the path carries it encoded"               grep -qF "/settings/Pump%20Fan%2F2/profile" "$FAKE_CC/calls"
pu="$(setting "$NCT" 'Pump Fan/2' profile_uid)"
check "  and the setting is on that channel"        has carbonite "$pu"

echo "## 17. the token is never on curl's command line"
# ps shows every process's argv to every user; the token can set any fan.
SECRET='cc_S3cret\to"k'
reset_cc; rm -rf "$CARB_CONFIG_DIR"; printf '%s\n' "$SECRET" > "$FAKE_CC/token"
CARB_TOKEN="$SECRET" eng apply --pin "${NCT:0:8}:fan1@100" --channels "${NCT:0:8}:fan3"
check "apply succeeded, the token sent on stdin"    is "$RC" 0
check "  a \\ and a \" in it survive curl's quoting" is "$(setting "$NCT" fan3 profile_uid)" carbonite
check "curl was run"                                bash -c "[[ -s '$FAKE_CC/argv' ]]"
check "  and its argv never held the token"         bash -c '! grep -qF -- "$1" "$2"' _ "$SECRET" "$FAKE_CC/argv"
check "  nor any Authorization header"              bash -c "! grep -q Authorization '$FAKE_CC/argv'"
: > "$FAKE_CC/argv"
CARB_TOKEN="" eng_in "$SECRET"$'\n' login
check "login from stdin works with it"              is "$RC" 0
CARB_TOKEN="" eng release --yes
check "  and the saved token is used"               is "$RC" 0
check "  never on curl's argv"                      bash -c '! grep -qF -- "$1" "$2"' _ "$SECRET" "$FAKE_CC/argv"

echo "## 18. a failed step stops everything after it"
F1="${NCT:0:8}:fan1" F2="${NCT:0:8}:fan2" F3="${NCT:0:8}:fan3"
reset_cc; echo 'PUT /devices/[^/]+/settings/fan1/manual' > "$FAKE_CC/fail"
eng apply --pin "${F1}@100" --channels "$F3"
check "a failed --pin fails apply"                  bash -c "(( $RC != 0 ))"
check "  saying the curve was not touched"          has "curve was not touched" "$OUT"
check "  and nothing was written after the pin"     bash -c "! grep -qE '^(POST|PUT) /(profiles|functions)|/fan3/' '$FAKE_CC/calls'"
check "  the fan the curve would take is untouched" is "$(setting "$NCT" fan3 profile_uid)" ""
reset_cc; eng apply --channels "${F2}@45 $F3"; : > "$FAKE_CC/calls"
echo 'PUT /devices/[^/]+/settings/fan2/profile' > "$FAKE_CC/fail"
eng apply --channels "$F3"
check "a failed hand-back fails apply"              bash -c "(( $RC != 0 ))"
check "  and nothing is pruned"                     bash -c "! grep -q '^DELETE ' '$FAKE_CC/calls'"
check "  the 45% set its fan still uses is kept"    is "$(prof carbonite-m45 .uid)" '"carbonite-m45"'
check "  and that fan is still on it"               is "$(setting "$NCT" fan2 profile_uid)" carbonite-m45
reset_cc; eng apply --channels "$F3"; : > "$FAKE_CC/calls"
echo 'PUT /devices/[^/]+/settings/fan3/profile' > "$FAKE_CC/fail"
eng release --yes
check "a failed hand-back fails release"            bash -c "(( $RC != 0 ))"
check "  saying it is not deleting"                 has "not deleting" "$OUT"
check "  and nothing was deleted"                   bash -c "! grep -q '^DELETE ' '$FAKE_CC/calls'"
check "  the function is kept too"                  grep -q carbonite-fn "$FAKE_CC/functions.json"
rm -f "$FAKE_CC/fail"

echo "## 19. a device whose settings cannot be read blocks pruning and deleting"
G1="${GPU:0:8}:fan1"
reset_cc; eng apply --channels "${F2}@45 $G1"; : > "$FAKE_CC/calls"
echo "GET /devices/${NCT}/settings" > "$FAKE_CC/fail"
eng apply --channels "$G1"
check "apply fails"                                 bash -c "(( $RC != 0 ))"
check "  naming the unreadable device"              has "${NCT:0:8}" "$OUT"
check "  and nothing is pruned"                     bash -c "! grep -q '^DELETE ' '$FAKE_CC/calls'"
check "  the fan there keeps its 45% set"           is "$(prof carbonite-m45 .uid)" '"carbonite-m45"'
rm -f "$FAKE_CC/fail"
eng apply --channels "$G1"
check "once readable, apply hands the fan back"     is "$(setting "$NCT" fan2 profile_uid)" 0
check "  and prunes its set"                        bash -c "! grep -q carbonite-m45 '$FAKE_CC/profiles.json'"
reset_cc; eng apply --channels "${F2}@45 $G1"
echo "GET /devices/${NCT}/settings" > "$FAKE_CC/fail-once"
eng apply --channels "$G1"
check "a read that fails once is retried"           is "$RC" 0
check "  and the fan is handed back"                is "$(setting "$NCT" fan2 profile_uid)" 0
reset_cc; eng apply --channels "$F3"; : > "$FAKE_CC/calls"
echo "GET /devices/${NCT}/settings" > "$FAKE_CC/fail"
eng release --yes
check "release fails"                               bash -c "(( $RC != 0 ))"
check "  deleting nothing"                          bash -c "! grep -q '^DELETE ' '$FAKE_CC/calls'"
check "  the fan keeps its profile"                 is "$(setting "$NCT" fan3 profile_uid)" carbonite
check "  and the function"                          grep -q carbonite-fn "$FAKE_CC/functions.json"
rm -f "$FAKE_CC/fail"

echo
(( FAILS == 0 )) && { echo "all passed"; exit 0; }
echo "${FAILS} failed"; exit 1
