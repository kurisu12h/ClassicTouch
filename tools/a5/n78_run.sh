#!/bin/bash
# n78_run.sh DIR KBOOT SECONDS [extra qemu args...]: boot n78 with the USB disk $DISK (default the 7.1.2
# two-partition disk; SNAP=off writes it) for SECONDS, then kill -9 (QEMU traps SIGALRM). Serial in DIR/serial.log,
# QMP at DIR/qmp.sock (tools/a5/qmon.py screenshots). Run from anywhere; paths are relative to the project root.
R=$1; K=$2; T=$3; shift 3
cd "$(dirname "$0")/../.."
mkdir -p $R && rm -f $R/qmp.sock
DISK=${DISK:-work/a5/disks/11D257-full-noprot.img}
perl -e '$p=fork; if(!$p){exec @ARGV} sleep '$T'; kill 9,$p; waitpid $p,0' -- work/a5/build/qemu-system-arm \
  -M iPod-Touch-5G,kboot=$K -display none -audio driver=none -serial file:$R/serial.log \
  -qmp unix:$R/qmp.sock,server,nowait -monitor none \
  -drive if=none,id=root,file=$DISK,format=raw,snapshot=${SNAP:-on} -device usb-storage,bus=ehci.0,drive=root "$@" > $R/qemu.out 2>&1
