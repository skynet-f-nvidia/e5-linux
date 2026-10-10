#!/bin/sh
# The board's USB gadget: ONE network function plus the ACM console, chosen by
# /etc/config/e5-usb, always bound with its netdev up and in br-lan.
#
# One network function, never two.  RNDIS beside a CDC function makes Windows
# bind the whole device to usbser and show no network adapter at all (measured;
# it is why the MU300 port drops the second function the moment RNDIS is made).
# What a host binds with no INF of its own: NCM (Windows 10 2004+ and 11 through
# their inbox UsbNcm.sys, macOS and Linux through their own drivers) and, for
# older Windows, RNDIS through the Microsoft OS descriptors below.  Windows has
# no ECM driver, so ECM is the fallback for hosts that have nothing else.
#
# /etc/config/e5-usb holds the mode, /usr/sbin/e5-usb-mode writes it:
#
#     auto   ncm, else ecm                 (the default)
#     ncm    ncm, else ecm
#     ecm    ecm, else ncm
#     rndis  rndis alone, with the MS OS descriptors
#
# The initramfs always starts from auto -- it runs before the root filesystem is
# mounted and cannot read the setting -- so a forced mode costs one rebind here.
#
# Measured details this keeps: the device class must be 0xEF/0x02/0x01 or Windows
# ignores the IADs and hands interfaces out one by one; bcdDevice must move when
# the shape does, or Windows reuses its cached MS-OS-descriptor answer (including
# "none"); and the netdev must be up before the host activates the function,
# since f_ncm/f_ecm report the link in their first CONNECT notification and the
# macOS ECM driver never picks up a later "connected".
set -u
G=/sys/kernel/config/usb_gadget/linux
[ -d "$G" ] || exit 0
UDC=${E5_GADGET_UDC:-musb-hdrc.1.auto}
C=$G/configs/c.1
RUN=/run/e5

MODE=$(uci -q get e5-usb.usb.mode 2>/dev/null || true)
case "${MODE:-auto}" in
    auto|ncm|ecm|rndis) MODE=${MODE:-auto} ;;
    *) MODE=auto ;;
esac
case "$MODE" in
    auto|ncm) LIST="ncm ecm" ;;
    ecm)      LIST="ecm ncm" ;;
    rndis)    LIST="rndis" ;;
esac

# the first function of the list this kernel can make is the one used
netf= rndis=
for f in $LIST; do
    case $f in
        rndis)
            [ -d "$G/functions/rndis.rn0" ] && { rndis=1; break; }
            mkdir "$G/functions/rndis.rn0" 2>/dev/null && { rndis=1; break; } ;;
        *)
            [ -d "$G/functions/$f.usb0" ] && { netf=$f; break; }
            mkdir "$G/functions/$f.usb0" 2>/dev/null && { netf=$f; break; } ;;
    esac
done
[ -n "$rndis" ] && netf=
made=$netf
[ -n "$rndis" ] && made=rndis
[ -n "$made" ] || made=none

# is what is bound already what the mode asks for?
stale=
for f in ncm ecm; do
    if [ "$f" = "$netf" ]; then
        readlink "$C/f1" 2>/dev/null | grep -q "/$f.usb0$" || stale=yes
    else
        [ -d "$G/functions/$f.usb0" ] && stale=yes
    fi
done
if [ -n "$rndis" ]; then
    readlink "$C/f1" 2>/dev/null | grep -q "/rndis.rn0$" || stale=yes
fi
[ -e "$C/f2" ] || stale=yes
cur=$(cat "$G/UDC" 2>/dev/null)

# every USB netdev: nothing of its own, up, in br-lan; RNDIS is renamed to rndis0
# so the CDC link keeps the name the bridge and the first-boot script expect
fix_netdevs() {
    if [ -n "$rndis" ]; then
        rn=$(cat "$G/functions/rndis.rn0/ifname" 2>/dev/null)
        case "$rn" in
            ""|"(unnamed net_device)"|rndis0) ;;
            *) ip link set "$rn" name rndis0 2>/dev/null ;;
        esac
    fi
    for d in /sys/class/net/usb* /sys/class/net/rndis*; do
        [ -e "$d" ] || continue
        n=$(basename "$d")
        ip -4 addr flush dev "$n" 2>/dev/null
        [ -e "/proc/sys/net/ipv6/conf/$n" ] && echo 1 > "/proc/sys/net/ipv6/conf/$n/disable_ipv6"
        ip link set "$n" up 2>/dev/null
        [ -e "/sys/class/net/br-lan/brif/$n" ] || ip link set "$n" master br-lan 2>/dev/null
    done
}
fix_netdevs

if [ -z "$stale" ] && [ -n "$cur" ]; then
    mkdir -p "$RUN" && echo "$made" > "$RUN/usb-net-applied"
    echo "gadget bound to $cur, mode=$MODE (made=$made)"
    exit 0
fi

echo "gadget stale (bound=$cur) -- mode=$MODE wants: $LIST (made=$made)"
[ -n "$cur" ] && echo "" > "$G/UDC"

rm -f "$C/f1" "$C/f2"
for f in ncm ecm; do
    [ "$f" = "$netf" ] && continue
    [ -d "$G/functions/$f.usb0" ] && rmdir "$G/functions/$f.usb0" 2>/dev/null
done
[ -z "$rndis" ] && [ -d "$G/functions/rndis.rn0" ] && rmdir "$G/functions/rndis.rn0" 2>/dev/null

if [ -n "$netf" ]; then
    [ -d "$G/functions/$netf.usb0" ] || mkdir -p "$G/functions/$netf.usb0"
    [ -n "$(cat "$G/functions/$netf.usb0/dev_addr" 2>/dev/null)" ]  || echo 02:50:00:00:e5:01 > "$G/functions/$netf.usb0/dev_addr"
    [ -n "$(cat "$G/functions/$netf.usb0/host_addr" 2>/dev/null)" ] || echo 02:50:00:00:e5:02 > "$G/functions/$netf.usb0/host_addr"
    ln -s "$G/functions/$netf.usb0" "$C/f1"
    echo "$netf net + ACM console" > "$C/strings/0x409/configuration"
    echo 0x0301 > "$G/bcdDevice"
    echo 0 > "$G/os_desc/use" 2>/dev/null
    [ -e "$G/os_desc/c.1" ] && rm -f "$G/os_desc/c.1"
elif [ -n "$rndis" ]; then
    echo 02:50:00:00:e5:03 > "$G/functions/rndis.rn0/dev_addr"
    echo 02:50:00:00:e5:04 > "$G/functions/rndis.rn0/host_addr"
    ln -s "$G/functions/rndis.rn0" "$C/f1"
    echo "RNDIS + ACM console" > "$C/strings/0x409/configuration"
    # 0x0302: a shape change must move bcdDevice, or Windows reuses the
    # MS-OS-descriptor answer it cached for the old one ("none" included)
    echo 0x0302 > "$G/bcdDevice"
    # Windows would hand the bare RNDIS control interface (02/02/ff) to usbser:
    # the Microsoft OS descriptors are what bind rndis.sys to it instead
    echo 1 > "$G/os_desc/use"
    echo 0xcd > "$G/os_desc/b_vendor_code"
    echo MSFT100 > "$G/os_desc/qw_sign"
    printf "RNDIS\0\0\0" > "$G/functions/rndis.rn0/os_desc/interface.rndis/compatible_id"
    printf "5162001\0"     > "$G/functions/rndis.rn0/os_desc/interface.rndis/sub_compatible_id"
    [ -e "$G/os_desc/c.1" ] || (cd "$G" && ln -s configs/c.1 os_desc/c.1)
fi
[ -d "$G/functions/acm.GS0" ] || mkdir -p "$G/functions/acm.GS0"
ln -s "$G/functions/acm.GS0" "$C/f2"

echo "$UDC" > "$G/UDC"
sleep 2
fix_netdevs
mkdir -p "$RUN" && echo "$made" > "$RUN/usb-net-applied"
echo "UDC=$(cat "$G/UDC") mode=$MODE made=$made netdevs=$(ls /sys/class/net | grep -E "^(usb|rndis)" | tr "\n" " ")"
