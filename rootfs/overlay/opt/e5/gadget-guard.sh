#!/bin/sh
# Two jobs, both about the USB gadget that is this board's network and its
# serial console at once:
#
#  * if something leaves it unbound, bind it to the UDC again;
#  * present the RNDIS function the way a Windows host matches it.
#
# The board's USB port is RNDIS-only on purpose: Windows 10/11 bind their
# in-box Rndismp driver to a device of class 0xEF/0x04/0x01 (miscellaneous,
# subclass 04, protocol 01), and a gadget whose device class stays 00/00/00 --
# what the CDC interface codes used to allow -- gets no driver at all on a
# Windows host: no adapter, no DHCP, while from this side the link looks
# healthy (enumerated, configured, netdev up with carrier: the composite core
# calls set_alt() by itself).  Measured: this shape links in ~3-8 s on every
# boot; the 0xEF/0x02/0x01 composite with ncm+acm beside it never did.  Linux
# hosts see the same netdev either way (rndis_host); NCM and the CDC-ACM
# console are gone -- Windows never matched the NCM function, and the console
# only mattered on a Linux host.
#
# The function's netdev must keep the name the rest of the system knows it by
# (usb1: br-lan's port, the firewall zones, the hotplug script).  With ncm
# gone it would be the first free u_ether name, usb0, so ifname is set here
# before the bind -- boot/init does the same for the first enumeration.
#
# The Microsoft OS descriptors are published as well.  Windows asks a device
# instance for them once, so they cannot be relied on for a rebooted device,
# but they are what the optional "USB RNDIS 6 Adapter" install path matches.
set -u
G=/sys/kernel/config/usb_gadget/linux
[ -d "$G" ] || exit 0
UDC=${E5_GADGET_UDC:-musb-hdrc.1.auto}
F=$G/functions/rndis.usb0
O=$F/os_desc/interface.rndis
C=$G/configs/c.1
REV=${E5_USB_REV:-0x0620}

stale=
same() {
    [ -e "$1" ] || { stale=yes; return; }
    [ "$(cat "$1" 2>/dev/null)" = "$2" ] || stale=yes
}
if [ -d "$O" ]; then
    same "$G/bDeviceClass"    0xef
    same "$G/bDeviceSubClass" 0x04
    same "$G/bDeviceProtocol" 0x01
    same "$F/class"    ef
    same "$F/subclass" 04
    same "$F/protocol" 01
    same "$F/ifname"   usb1
    same "$G/bcdDevice" "$REV"
    same "$O/compatible_id"     RNDIS
    same "$O/sub_compatible_id" 5162001
    same "$G/os_desc/use" 1
    same "$G/os_desc/b_vendor_code" 0xcd
    same "$G/os_desc/qw_sign" MSFT100
    [ -e "$G/os_desc/c.1" ] || stale=yes
    # RNDIS only: the old NCM and ACM functions must not be in the config
    [ -e "$C/f1" ] && stale=yes
    [ -e "$C/f2" ] && stale=yes
fi

cur=$(cat "$G/UDC" 2>/dev/null)
if [ -z "$stale" ] && [ -n "$cur" ]; then
    echo "gadget bound to $cur, RNDIS class codes and MS OS descriptors ok"
    exit 0
fi

echo "gadget stale (bound=${cur:-no}) -- reconfigure and re-enumerate"
[ -n "$cur" ] && echo "" > "$G/UDC"          # descriptors only change while unbound
if [ -d "$O" ]; then
    rm -f "$C/f1" "$C/f2"                    # RNDIS only (older images had ncm/acm too)
    # the netdev name only changes while the function is not bound
    echo usb1 > "$F/ifname" 2>/dev/null
    echo 0xEF > "$G/bDeviceClass"
    echo 0x04 > "$G/bDeviceSubClass"
    echo 0x01 > "$G/bDeviceProtocol"
    echo EF > "$F/class"
    echo 4  > "$F/subclass"
    echo 1  > "$F/protocol"
    echo "$REV" > "$G/bcdDevice"
    # 8-byte fields, NUL padded: the configfs store copies exactly what it is
    # given and leaves the rest of the field alone, so a shorter write would
    # keep the tail of whatever was there before (a repaired ID once read back
    # as "RNDISID").
    printf 'RNDIS\0\0\0' > "$O/compatible_id"
    printf '5162001\0'     > "$O/sub_compatible_id"
    echo 0xcd    > "$G/os_desc/b_vendor_code"
    echo MSFT100 > "$G/os_desc/qw_sign"      # its store drops the newline
    echo 1       > "$G/os_desc/use"
    # the link must be made with a path that configfs resolves against the
    # gadget: "$G/os_desc/c.1 -> configs/c.1"
    [ -e "$G/os_desc/c.1" ] || (cd "$G" && ln -s configs/c.1 os_desc/c.1)
fi
echo "$UDC" > "$G/UDC"
sleep 2
echo "UDC=$(cat "$G/UDC") class=$(cat "$G/bDeviceClass")/$(cat "$F/class") ifname=$(cat "$F/ifname" 2>/dev/null) os_desc=$(cat "$G/os_desc/use" 2>/dev/null)"
