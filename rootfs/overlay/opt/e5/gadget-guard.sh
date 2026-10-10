#!/bin/sh
# Keep the board's USB gadget bound, in the protocol shape the host expects.
#
# Two network functions are offered by default ("auto"): RNDIS, which Windows
# binds with its in-box Rndismp driver, and CDC-ECM, which macOS and most
# non-Windows hosts bind (Linux binds both, and both its netdevs join br-lan).
# /etc/config/e5-usb can narrow that down:
#
#     config usb 'usb'
#         option mode 'auto'          # auto | rndis | ecm
#
# e5-usb-mode(1) edits it and applies the change immediately.  The initramfs
# always starts from "auto" -- it runs before the root filesystem is mounted,
# so it cannot read the setting -- which is why this may re-enumerate once at
# boot when one protocol is forced.
#
# The function netdevs must be up and in br-lan.  An interface left down
# enumerates, looks configured from the host side, and carries not one packet
# (that is not hypothetical: it cost an evening), so they are put right here
# and not only in the first-boot hotplug script.
set -u
G=/sys/kernel/config/usb_gadget/linux
[ -d "$G" ] || exit 0
UDC=${E5_GADGET_UDC:-musb-hdrc.1.auto}
C=$G/configs/c.1
R=$G/functions/rndis.usb0
E=$G/functions/ecm.usb0

MODE=$(uci -q get e5-usb.usb.mode 2>/dev/null || true)
case "${MODE:-auto}" in
    auto|rndis|ecm) MODE=${MODE:-auto} ;;
    *) MODE=auto ;;
esac
want_rndis=no want_ecm=no
case "$MODE" in
    auto)  want_rndis=yes; want_ecm=yes ;;
    rndis) want_rndis=yes ;;
    ecm)   want_ecm=yes ;;
esac

# CDC-ECM only exists in images whose kernel was built with it: if this one
# cannot create the function, say so and keep the RNDIS side working.
if [ "$want_ecm" = yes ] && [ ! -d "$E" ] && ! mkdir "$E" 2>/dev/null; then
    echo "e5-usb: this kernel has no CDC-ECM; continuing with RNDIS only" >&2
    want_ecm=no
    [ "$want_rndis" = no ] && want_rndis=yes
fi

stale=
[ "$want_rndis" = yes ] && [ ! -d "$R" ] && stale=yes
[ "$want_rndis" = no ]  && [ -d "$R" ]  && stale=yes
[ "$want_ecm" = yes ]   && [ ! -d "$E" ] && stale=yes
[ "$want_ecm" = no ]    && [ -d "$E" ]  && stale=yes
[ "$want_rndis" = yes ] && [ ! -e "$C/f3" ] && stale=yes
[ "$want_rndis" = no ]  && [ -e "$C/f3" ]  && stale=yes
[ "$want_ecm" = yes ]   && [ ! -e "$C/f1" ] && stale=yes
[ "$want_ecm" = no ]    && [ -e "$C/f1" ]  && stale=yes
# a link left behind by an older image (the NCM/ACM composite)
[ -e "$C/f2" ] && stale=yes

cur=$(cat "$G/UDC" 2>/dev/null)

# every USB netdev: no IPv4 of its own, IPv6 off, up, in br-lan
fix_netdevs() {
    for d in /sys/class/net/usb*; do
        [ -e "$d" ] || continue
        n=${d##*/}
        ip -4 addr flush dev "$n" 2>/dev/null
        [ -e "/proc/sys/net/ipv6/conf/$n" ] && echo 1 > "/proc/sys/net/ipv6/conf/$n/disable_ipv6"
        ip link set "$n" up 2>/dev/null
        [ -e "/sys/class/net/br-lan/brif/$n" ] || ip link set "$n" master br-lan 2>/dev/null
    done
}
fix_netdevs

if [ -z "$stale" ] && [ -n "$cur" ]; then
    echo "gadget bound to $cur, mode=$MODE (rndis=$want_rndis ecm=$want_ecm)"
    exit 0
fi

echo "gadget stale (bound=${cur:-no}) -- applying mode=$MODE (rndis=$want_rndis ecm=$want_ecm)"
[ -n "$cur" ] && echo "" > "$G/UDC"          # descriptors only change while unbound

# drop the links first: a function cannot be removed while it is linked
rm -f "$C/f1" "$C/f2" "$C/f3"
if [ "$want_ecm" = yes ]; then
    [ -d "$E" ] || mkdir -p "$E"
    [ -n "$(cat "$E/dev_addr" 2>/dev/null)" ]  || echo 02:50:00:00:e5:11 > "$E/dev_addr"
    [ -n "$(cat "$E/host_addr" 2>/dev/null)" ] || echo 02:50:00:00:e5:12 > "$E/host_addr"
    ln -s "$E" "$C/f1"
elif [ -d "$E" ]; then
    rmdir "$E" 2>/dev/null
fi
if [ "$want_rndis" = yes ]; then
    [ -d "$R" ] || mkdir -p "$R"
    [ -n "$(cat "$R/dev_addr" 2>/dev/null)" ]  || echo 02:50:00:00:e5:13 > "$R/dev_addr"
    [ -n "$(cat "$R/host_addr" 2>/dev/null)" ] || echo 02:50:00:00:e5:14 > "$R/host_addr"
    ln -s "$R" "$C/f3"
elif [ -d "$R" ]; then
    rmdir "$R" 2>/dev/null
fi

echo "$UDC" > "$G/UDC"
sleep 2
fix_netdevs
echo "UDC=$(cat "$G/UDC") mode=$MODE functions=$(ls $G/functions | tr '\n' ' ') netdevs=$(ls /sys/class/net | grep -E '^usb' | tr '\n' ' ')"
