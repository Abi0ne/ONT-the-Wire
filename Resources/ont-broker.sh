#!/bin/bash
# Root broker, one per app run. Started once at launch (single administrator
# authorization) through ont-root-helper; reads commands from the app's
# private pipe on stdin and answers on stdout:
#
#   START <session-dir> <interface> <vlan|-> <primary 0|1>   -> STARTED | ERROR <msg>
#   PING                                                      -> PONG
#
# Sessions are stopped through the `stop` file in their folder (see
# ont-session.sh). When the app quits, the pipe closes and the broker exits;
# a running session notices the app is gone and stops on its own.

set -u
PATH=/usr/bin:/bin:/usr/sbin:/sbin

BASE=$(cd "$(dirname "$0")" && pwd)
SESSION_SCRIPT=$BASE/ont-session.sh
RELAY=$BASE/pppoe-relay
APP_PID=${1:-}

[[ $APP_PID =~ ^[0-9]+$ ]] || { echo "ERROR PID non valido"; exit 2; }
[[ $(id -u) == 0 ]] || { echo "ERROR non sono root"; exit 2; }
[[ -f $SESSION_SCRIPT && -x $RELAY ]] || { echo "ERROR componenti mancanti"; exit 2; }

echo "READY"
while read -r cmd dir iface vlan primary; do
    case $cmd in
    START)
        if [[ -z ${dir:-} || -z ${iface:-} || -z ${vlan:-} || -z ${primary:-} ]]; then
            echo "ERROR comando incompleto"
            continue
        fi
        ONT_SESSION_DETACHED=1 /bin/bash "$SESSION_SCRIPT" "$dir" "$RELAY" "$iface" "$vlan" "$primary" "$APP_PID" \
            >>"$dir/supervisor.log" 2>&1 </dev/null &
        echo "STARTED"
        ;;
    PING)
        echo "PONG"
        ;;
    *)
        echo "ERROR comando sconosciuto"
        ;;
    esac
done
