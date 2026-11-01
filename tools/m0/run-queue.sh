#!/bin/bash
# M0: the measured runs one after another (never two emulators measuring at once), host load before and after each.
# usage: run-queue.sh NAME:DEVICE:BUILD ...   e.g. n90-jit-1:n90ap-11D257:jit
cd /path/to/classic-ios
for spec in "$@"; do
    IFS=: read -r name device build <<< "$spec"
    log=work/runs/$name.log
    {
        echo "uptime-before: $(uptime)"
        python3 tools/m0/bench.py run --device work/devices/$device --golden work/states/$device \
            --build $build --out work/runs/$name
        echo "exit=$?"
        echo "uptime-after: $(uptime)"
    } > "$log" 2>&1
    echo "$(date +%H:%M:%S) $name done: $(grep '^exit=' "$log")"
done
