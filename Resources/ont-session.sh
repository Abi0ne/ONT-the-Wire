#!/bin/bash
# Root supervisor for one PPPoE session, started in the background by
# ont-broker.sh (stdout/stderr go to <session-dir>/supervisor.log):
#
#   ont-session.sh <session-dir> <relay> <interface> <vlan|-> <primary 0|1> <app-pid>
#
# <session-dir> is private to the user (0700) and holds `secret` (pppd `user`
# and `password` lines). The script moves the secret to a root-only file, runs
# pppd with pppoe-relay as its pty transport, and stops the session when the
# app creates <session-dir>/stop or exits. Logs: relay.log and pppd.log; on
# exit it writes pppd's exit status to <session-dir>/exit.

set -u
PATH=/usr/bin:/bin:/usr/sbin:/sbin

DIR=$1 RELAY=$2 IFACE=$3 VLAN=$4 PRIMARY=$5 APP_PID=$6
SERVICE_KEY=State:/Network/Service/it.ontthewire.pppoe

fail() { echo "ont-session: $*" >&2; exit 2; }
[[ -d $DIR && ! -L $DIR ]] || fail "cartella di sessione non valida"
[[ -f $RELAY && -x $RELAY ]] || fail "pppoe-relay non trovato"
[[ $DIR != *"'"* && $RELAY != *"'"* ]] || fail "percorsi con apici non supportati"
[[ $IFACE =~ ^[a-z]+[0-9]+$ ]] || fail "interfaccia non valida"
[[ $VLAN == - || $VLAN =~ ^[0-9]{1,4}$ ]] || fail "VLAN non valida"
[[ $PRIMARY == 0 || $PRIMARY == 1 ]] || fail "opzione principale non valida"
[[ $APP_PID =~ ^[0-9]+$ ]] || fail "PID non valido"

echo "$(date +%H:%M:%S) supervisore avviato (pid $$, uid $(id -u))"

SECRET=$(mktemp /var/run/ontthewire.XXXXXX) || exit 2
chmod 600 "$SECRET"
cat "$DIR/secret" >"$SECRET" 2>/dev/null
rm -f "$DIR/secret"

PPPD_PID=
PUBLISHED=0

unpublish() {
    [[ $PUBLISHED == 1 ]] || return
    printf 'remove %s/IPv4\nremove %s/DNS\n' "$SERVICE_KEY" "$SERVICE_KEY" | scutil
    PUBLISHED=0
}

cleanup() {
    if [[ -n $PPPD_PID ]] && kill -0 "$PPPD_PID" 2>/dev/null; then
        kill -TERM "$PPPD_PID" 2>/dev/null
        for _ in 1 2 3 4 5 6 7 8 9 10; do kill -0 "$PPPD_PID" 2>/dev/null || break; sleep 0.5; done
        kill -KILL "$PPPD_PID" 2>/dev/null
    fi
    unpublish
    rm -f "$SECRET"
}
trap cleanup EXIT
trap '' HUP
trap 'exit 1' TERM INT

# Makes the PPP link the primary service (default route and DNS) the way VPN
# clients do: a State-only service with OverridePrimary. Removed on exit.
publish_primary() {
    local log=$DIR/pppd.log ifname local_ip remote_ip dns
    ifname=$(sed -En 's/.*Using interface (ppp[0-9]+).*/\1/p' "$log" | tail -1)
    local_ip=$(sed -En 's/.*local +IP address ([0-9.]+).*/\1/p' "$log" | tail -1)
    remote_ip=$(sed -En 's/.*remote IP address ([0-9.]+).*/\1/p' "$log" | tail -1)
    dns=$(sed -En 's/.*(primary|secondary) +DNS address ([0-9.]+).*/\2/p' "$log" | tr '\n' ' ')
    [[ -n $ifname && -n $local_ip && -n $remote_ip ]] || return 1
    {
        echo "d.init"
        echo "d.add Addresses * $local_ip"
        echo "d.add DestAddresses * $remote_ip"
        echo "d.add Router $remote_ip"
        echo "d.add InterfaceName $ifname"
        echo "d.add OverridePrimary # 1"
        echo "set $SERVICE_KEY/IPv4"
        if [[ -n ${dns// /} ]]; then
            echo "d.init"
            echo "d.add ServerAddresses * $dns"
            echo "set $SERVICE_KEY/DNS"
        fi
    } | scutil
    PUBLISHED=1
    echo "$(date +%H:%M:%S) ont-session: STATUS primary $ifname via $remote_ip dns=$dns" >>"$DIR/relay.log"
}

# pppd runs the pty command through /bin/sh: quote the paths (the app bundle
# name contains spaces).
PTY="'$RELAY' -I $IFACE -T 30 -L '$DIR/relay.log'"
[[ $VLAN != - ]] && PTY="$PTY -V $VLAN"

pppd pty "$PTY" file "$SECRET" nodetach debug logfile "$DIR/pppd.log" \
    noauth noipdefault usepeerdns mtu 1492 mru 1492 \
    noaccomp nopcomp novj noccp \
    lcp-echo-interval 10 lcp-echo-failure 4 maxfail 1 \
    >/dev/null 2>&1 &
PPPD_PID=$!
echo $$ >"$DIR/supervisor.pid"

STATUS=
while :; do
    if ! kill -0 "$PPPD_PID" 2>/dev/null; then
        wait "$PPPD_PID"; STATUS=$?
        break
    fi
    if [[ -e $DIR/stop ]] || ! kill -0 "$APP_PID" 2>/dev/null; then
        kill -TERM "$PPPD_PID" 2>/dev/null
        for _ in $(seq 1 20); do kill -0 "$PPPD_PID" 2>/dev/null || break; sleep 0.5; done
        kill -KILL "$PPPD_PID" 2>/dev/null
        wait "$PPPD_PID"; STATUS=$?
        break
    fi
    if [[ $PRIMARY == 1 && $PUBLISHED == 0 ]] && grep -q 'local  *IP address' "$DIR/pppd.log" 2>/dev/null; then
        publish_primary
    fi
    sleep 0.5
done
PPPD_PID=
unpublish
echo "${STATUS:-1}" >"$DIR/exit"
