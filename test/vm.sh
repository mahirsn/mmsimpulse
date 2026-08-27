#!/bin/bash
# Install and run mmsimpulse in a throwaway Arch VM, the way a stranger with only
# KDE would: nothing from this machine's session leaks in.
#
#   test/vm.sh up [gui]    boot the VM; `gui` opens a window you can drive by hand
#   test/vm.sh ssh <cmd>   run a command inside the VM
#   test/vm.sh click X Y [btn]  click in the guest, through its virtio tablet
#   test/vm.sh shot <name> screenshot the VM's framebuffer into test/shots/
#   test/vm.sh serial      tail the guest serial console
#   test/vm.sh down        stop the VM
set -uo pipefail

REPO="$(dirname "$(dirname "$(readlink -f "$0")")")"
VM="$REPO/.vm"
SHOTS="$REPO/test/shots"
SSH_PORT=2222
HTTP_PORT=8000
mkdir -p "$VM" "$SHOTS"

ssh_vm() {
    ssh -q -i "$VM/id_vm" -p "$SSH_PORT" \
        -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=5 -o LogLevel=ERROR tester@127.0.0.1 "$@"
}

case "${1:-}" in
up)
    [[ -f "$VM/base.qcow2" ]] || { echo "base.qcow2 yok; once indir" >&2; exit 1; }
    # `gui` puts the guest in a window on this desktop. Screenshots and the
    # scripted input still go through QMP either way, so both work at once.
    DISPLAY_MODE=none
    [[ "${2:-}" == gui ]] && DISPLAY_MODE=gtk
    "$0" down >/dev/null 2>&1

    # cloud-init NoCloud over SMBIOS+HTTP: mtools here cannot write the VFAT long
    # names a CIDATA image needs, and there is no ISO writer installed.
    mkdir -p "$VM/cidata"
    [[ -f "$VM/id_vm" ]] || ssh-keygen -q -t ed25519 -N "" -f "$VM/id_vm" -C mmsimpulse-vm
    cat > "$VM/cidata/meta-data" <<EOF
instance-id: mmsimpulse-test
local-hostname: mmsimpulse-vm
EOF
    cat > "$VM/cidata/user-data" <<EOF
#cloud-config
users:
  - name: tester
    groups: [wheel]
    sudo: ["ALL=(ALL) NOPASSWD:ALL"]
    shell: /bin/bash
    lock_passwd: false
    plain_text_passwd: tester
    ssh_authorized_keys:
      - $(cat "$VM/id_vm.pub")
ssh_pwauth: true
disable_root: false
chpasswd:
  list: |
    root:root
  expire: false
EOF
    : > "$VM/cidata/vendor-data"
    (cd "$VM/cidata" && setsid python3 -m http.server "$HTTP_PORT" --bind 127.0.0.1 \
        >"$VM/http.log" 2>&1 </dev/null & echo $! > "$VM/http.pid")

    [[ -f "$VM/disk.qcow2" ]] || {
        qemu-img create -f qcow2 -F qcow2 -b "$VM/base.qcow2" "$VM/disk.qcow2" 40G >/dev/null
    }

    rm -f "$VM/qmp.sock"
    setsid qemu-system-x86_64 \
        -enable-kvm -cpu host -smp 8 -m 8192 \
        -drive file="$VM/disk.qcow2",if=virtio,cache=writeback \
        -nic user,model=virtio-net-pci,hostfwd=tcp::$SSH_PORT-:22 \
        -smbios "type=1,serial=ds=nocloud;s=http://10.0.2.2:$HTTP_PORT/" \
        -device virtio-vga,xres=1920,yres=1080 \
        -device virtio-tablet-pci -device virtio-keyboard-pci \
        -display "$DISPLAY_MODE" -qmp "unix:$VM/qmp.sock,server,nowait" \
        -serial "file:$VM/serial.log" \
        >"$VM/qemu.log" 2>&1 </dev/null &
    echo $! > "$VM/qemu.pid"

    echo -n "acilis bekleniyor"
    for _ in $(seq 1 120); do
        ssh_vm true 2>/dev/null && { echo " -> ssh hazir"; exit 0; }
        echo -n .; sleep 5
    done
    echo " -> ssh gelmedi; test/vm.sh serial ile bak" >&2
    exit 1
    ;;

ssh)
    shift; ssh_vm "$@"
    ;;

type|key|keydown|keyup)
    # test/vm.sh type <text> | test/vm.sh key <qcode>...
    what="$1"; shift
    python3 "$REPO/test/qmp.py" "$VM/qmp.sock" "$what" "$@"
    ;;

click|move)
    # test/vm.sh click <x> <y> [left|right]   coordinates in guest pixels
    python3 "$REPO/test/qmp.py" "$VM/qmp.sock" "$1" "$2" "$3" "${4:-left}"
    ;;

shot)
    out="$SHOTS/${2:-vm}.png"
    python3 "$REPO/test/qmp.py" "$VM/qmp.sock" screendump "$VM/shot.ppm" || exit 1
    magick "$VM/shot.ppm" "$out" && echo "$out"
    ;;

serial)
    tail -n "${2:-40}" "$VM/serial.log"
    ;;

down)
    for p in qemu http; do
        [[ -f "$VM/$p.pid" ]] && kill "$(cat "$VM/$p.pid")" 2>/dev/null
        rm -f "$VM/$p.pid"
    done
    rm -f "$VM/qmp.sock"
    echo down
    ;;

*)
    sed -n '2,10p' "$0"
    ;;
esac
