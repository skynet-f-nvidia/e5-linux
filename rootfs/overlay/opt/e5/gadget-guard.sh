#!/bin/sh
# Keep the board's USB gadget bound and in the shape this host matches.
#
# That shape is RNDIS and nothing else, built the way Android builds it (AOSP
# rootdir/init.usb.configfs.rc): create functions/rndis.usb0 and link it into
# the configuration.  Windows binds its in-box Rndismp driver to the RNDIS
# interface descriptors alone -- that is why every phone works without an INF --
# and the class-code and Microsoft-OS-descriptor routes tried before this both
# failed in practice: Windows decides per device instance and caches the verdict
# (osvc), so a device it has once seen in another shape keeps that answer even
# across new PIDs and re-plugs.  Linux does not care either way (rndis_host
# matches the same descriptors).
#
# The netdev name is the one u_ether gives when the function is created, usb0
# here; the ifname attribute cannot be changed afterwards, so boot/init brings
# up usb0 and 10-e5-usb0 joins it to br-lan.  Nothing else in the image depends
# on the name.
set -u
G=/sys/kernel/config/usb_gadget/linux
[ -d "$G" ] || exit 0
UDC=${E5_GADGET_UDC:-musb-hdrc.1.auto}
F=$G/functions/rndis.usb0
C=$G/configs/c.1

stale=
if [ -d "$F" ]; then
    # RNDIS only: the old ncm/acm functions must not be in the configuration,
    # and the tail of an older Microsoft-OS-descriptor setup must be gone
    [ -e "$C/f1" ] && stale=yes
    [ -e "$C/f2" ] && stale=yes
    [ -e "$G/os_desc/use" ] && [ "$(cat "$G/os_desc/use" 2>/dev/null)" != 0 ] && stale=yes
fi

cur=$(cat "$G/UDC" 2>/dev/null)
if [ -z "$stale" ] && [ -n "$cur" ]; then
    echo "gadget bound to $cur, RNDIS only"
    exit 0
fi

echo "gadget stale (bound=${cur:-no}) -- reconfigure and re-enumerate"
[ -n "$cur" ] && echo "" > "$G/UDC"
if [ -d "$F" ]; then
    rm -f "$C/f1" "$C/f2"
    echo 0 > "$G/os_desc/use" 2>/dev/null
    [ -e "$G/os_desc/c.1" ] && rm -f "$G/os_desc/c.1"
    [ -e "$C/f3" ] || ln -s "$F" "$C/f3"
fi
[ -x /usr/libexec/usb-netdev-up ] && /usr/libexec/usb-netdev-up
echo "$UDC" > "$G/UDC"
sleep 2
echo "UDC=$(cat "$G/UDC") functions=$(ls $G/functions | tr '\n' ' ')"
