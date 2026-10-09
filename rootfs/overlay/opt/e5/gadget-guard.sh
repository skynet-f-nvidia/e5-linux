#!/bin/sh
# Two jobs, both about the USB gadget that is this board's network and its
# serial console at once:
#
#  * if something leaves it unbound, bind it to the UDC again;
#  * present the RNDIS function the way a Windows host can match it.
#
# That second job is what makes the USB port useful on Windows.  Windows 10
# and 11 no longer match RNDIS by the CDC interface codes, and the Microsoft
# OS descriptor ("WCID") route is answered at most once per device instance --
# a device that is ever seen without it is never asked for it again, so it
# cannot be relied on after a reboot.  What is deterministic is the class
# match: bDeviceClass 0xEF/0x02/0x01 declares a multi-interface function
# device (the IADs then decide which driver matches each function), and the
# RNDIS function's own IAD is set to 0xEF/0x04/0x01, which is exactly what
# Rndismp.inf is documented to bind to ("Miscellaneous (EFh), supports
# SubClass 04h and Protocol 01h").  The MS OS descriptors are published as
# well: harmless here, and they are what the optional "USB RNDIS 6 Adapter"
# install path uses.
#
# boot/init sets all of this before the gadget's first enumeration.  This
# covers a gadget that came up from an older initramfs, so the values are
# written -- and the gadget re-enumerated -- only when they are actually
# wrong.  Nothing here is cached by the host, unlike the WCID, so repeating
# it after every boot is enough.
set -u
G=/sys/kernel/config/usb_gadget/linux
[ -d "$G" ] || exit 0
UDC=${E5_GADGET_UDC:-musb-hdrc.1.auto}
F=$G/functions/rndis.usb0
O=$F/os_desc/interface.rndis
REV=${E5_USB_REV:-0x0620}   # keep in step with boot/init

stale=
same() {
    [ -e "$1" ] || { stale=yes; return; }
    [ "$(cat "$1" 2>/dev/null)" = "$2" ] || stale=yes
}
if [ -d "$O" ]; then
    same "$G/bDeviceClass"    0xef
    same "$G/bDeviceSubClass" 0x02
    same "$G/bDeviceProtocol" 0x01
    same "$F/class"    ef
    same "$F/subclass" 04
    same "$F/protocol" 01
    same "$G/bcdDevice" "$REV"
    same "$O/compatible_id"     RNDIS
    same "$O/sub_compatible_id" 5162001
    same "$G/os_desc/use" 1
    same "$G/os_desc/b_vendor_code" 0xcd
    same "$G/os_desc/qw_sign" MSFT100
    [ -e "$G/os_desc/c.1" ] || stale=yes
fi

cur=$(cat "$G/UDC" 2>/dev/null)
if [ -z "$stale" ] && [ -n "$cur" ]; then
    echo "gadget bound to $cur, RNDIS class codes and MS OS descriptors ok"
    exit 0
fi

echo "gadget stale (bound=${cur:-no}) -- reconfigure and re-enumerate"
[ -n "$cur" ] && echo "" > "$G/UDC"          # descriptors only change while unbound
if [ -d "$O" ]; then
    # Rndismp.inf's match, with the IAD carrying the RNDIS function class:
    # 0xEF/0x02/0x01 = multi-interface function device (look at the IADs),
    # 0xEF/0x04/0x01 = the RNDIS function's IAD.
    echo 0xEF > "$G/bDeviceClass"
    echo 0x02 > "$G/bDeviceSubClass"
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
echo "UDC=$(cat "$G/UDC") class=$(cat "$G/bDeviceClass")/$(cat "$F/class") os_desc=$(cat "$G/os_desc/use" 2>/dev/null)"
