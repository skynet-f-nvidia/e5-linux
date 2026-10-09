#!/bin/sh
# Two jobs, both about the USB gadget that is this board's network and its
# serial console at once:
#
#  * if something leaves it unbound, bind it to the UDC again;
#  * publish the RNDIS function's Microsoft OS descriptors.
#
# The second one is what makes the USB port useful on a Windows host at all.
# Windows no longer matches RNDIS by USB class code: the in-box Rndis driver
# binds to the extended compatible ID "RNDIS"/"5162001" (Microsoft OS 1.0
# descriptors, appendix 1), and Windows asks a device for Microsoft OS
# descriptors only once -- a gadget that answers the 0xEE string request with
# nothing is never asked again.  Without them Windows loads no driver, and
# from this side the failure looks like a healthy link: enumerated,
# configured, the netdev up with carrier on (the composite core calls
# set_alt() by itself) -- but not one frame either way.
#
# boot/init publishes them before the gadget's first enumeration.  This covers
# a gadget that came up from an older initramfs, so the values are written --
# and the gadget re-enumerated -- only when they are actually wrong.  The
# revision is the one Windows has enrolled together with the ID; keep it in
# step with boot/init (E5_USB_REV overrides it).
set -u
G=/sys/kernel/config/usb_gadget/linux
[ -d "$G" ] || exit 0
UDC=${E5_GADGET_UDC:-musb-hdrc.1.auto}
F=$G/functions/rndis.usb0
O=$F/os_desc/interface.rndis
REV=${E5_USB_REV:-0x0619}

stale=
same() {
    [ -e "$1" ] || { stale=yes; return; }
    [ "$(cat "$1" 2>/dev/null)" = "$2" ] || stale=yes
}
if [ -d "$O" ]; then
    same "$G/bcdDevice" "$REV"
    same "$O/compatible_id" RNDIS
    same "$O/sub_compatible_id" 5162001
    same "$G/os_desc/use" 1
    same "$G/os_desc/b_vendor_code" 0xcd
    same "$G/os_desc/qw_sign" MSFT100
    [ -e "$G/os_desc/c.1" ] || stale=yes
fi

cur=$(cat "$G/UDC" 2>/dev/null)
if [ -z "$stale" ] && [ -n "$cur" ]; then
    echo "gadget bound to $cur, MS OS descriptors ok"
    exit 0
fi

echo "gadget stale (bound=${cur:-no}) -- reconfigure and re-enumerate"
[ -n "$cur" ] && echo "" > "$G/UDC"          # os_desc only changes while unbound
if [ -d "$O" ]; then
    echo "$REV" > "$G/bcdDevice"
    # 8-byte fields, NUL padded: the configfs store copies exactly what it is
    # given and leaves the rest of the field alone, so a shorter write would
    # keep the tail of whatever was there before (that is how a repaired ID
    # once read back as "RNDISID").
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
echo "UDC=$(cat "$G/UDC") os_desc=$(cat "$G/os_desc/use" 2>/dev/null)"
