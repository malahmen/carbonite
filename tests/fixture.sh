# Sourced by the tests (here and in scomp-link): the fake CoolerControl's
# starting state, as JSON files in $FAKE_CC. reset_cc rebuilds it.
# shellcheck shell=bash

NCT=7bfee7e1aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
CPU=51acffcebbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
GPU=e5345c5fcccccccccccccccccccccccccccccccccccccccccccccccccccccccc

reset_cc() {
    rm -rf "$FAKE_CC"; mkdir -p "$FAKE_CC"
    echo tok > "$FAKE_CC/token"; : > "$FAKE_CC/calls"
    local so='{"min_duty":0,"max_duty":100,"fixed_enabled":true,"extension":null}'
    cat > "$FAKE_CC/devices.json" <<EOF
{"devices":[
 {"name":"nct6687","uid":"$NCT","info":{
   "temps":{"temp1":{"label":"Cpu","number":1}},
   "channels":{"fan1":{"label":"CPU Fan","speed_options":$so},
               "fan2":{"label":"Pump Fan","speed_options":$so},
               "fan3":{"label":"System Fan #1","speed_options":$so},
               "fan7":{"label":"System Fan #5","speed_options":$so}}}},
 {"name":"12th Gen Intel(R) Core(TM) i5-12400F","uid":"$CPU","info":{
   "temps":{"temp1":{"label":"CPU Temp Package Id 0","number":1},
            "temp2":{"label":"CPU Temp Core 0","number":2}},
   "channels":{"CPU Load":{"label":"CPU Load","speed_options":null}}}},
 {"name":"NVIDIA GeForce RTX 5060 Ti","uid":"$GPU","info":{
   "temps":{"GPU Temp":{"label":"GPU Temp","number":1}},
   "channels":{"fan1":{"label":"fan1","speed_options":$so}}}}
]}
EOF
    cat > "$FAKE_CC/status.json" <<EOF
{"devices":[
 {"uid":"$NCT","status_history":[{"temps":[{"name":"temp1","temp":42.0}],
   "channels":[{"name":"fan1","rpm":1120,"duty":34.5},{"name":"fan2","rpm":2850,"duty":100.0},
               {"name":"fan3","rpm":3022,"duty":60.0},{"name":"fan7","rpm":0,"duty":60.0}]}]},
 {"uid":"$CPU","status_history":[{"temps":[{"name":"temp1","temp":43.4},{"name":"temp2","temp":41.0}]}]},
 {"uid":"$GPU","status_history":[{"temps":[{"name":"GPU Temp","temp":36.0}],"channels":[{"name":"fan1","rpm":0,"duty":0.0}]}]}
]}
EOF
    echo '{"profiles":[{"uid":"0","name":"Default Profile","p_type":"Default","function_uid":"0","member_profile_uids":[]}]}' > "$FAKE_CC/profiles.json"
    echo '{"functions":[{"uid":"0","name":"Default Function","f_type":"Identity"}]}' > "$FAKE_CC/functions.json"
}

