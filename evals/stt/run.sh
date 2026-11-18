#!/bin/zsh
# Reproduces the speech-recognition comparison. Usage: evals/stt/run.sh <work_dir>
# Makes the clips with macOS `say`, runs the audio pipelines, then scores Deepgram and Apple on-device.
set -e
W=${1:?work dir}; E=${0:A:h}
mkdir -p "$W/clips" && cp "$E/phrases.txt" "$W/"
i=0; while IFS= read -r p; do i=$((i+1)); say -o "$W/clips/p$i.aiff" "$p"; afconvert -f WAVE -d LEF32@48000 -c 1 "$W/clips/p$i.aiff" "$W/clips/p$i.wav"; rm "$W/clips/p$i.aiff"; done < "$E/phrases.txt"
swiftc -O "$E/pipeline.swift" -o "$W/pipeline"
swiftc -O "$E/apple_stt.swift" -o "$W/apple_stt" -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker "$E/Info.plist"
for cond in clean:0.006 noisy:0.06; do n=${cond%%:*}; a=${cond##*:}; rm -rf "$W/out"; mkdir "$W/out"; "$W/pipeline" "$W" "$a"; mkdir -p "$W/cond_$n"; cp "$W"/out/*_NEW_x1.raw "$W/cond_$n/"; done
python3 - "$W" <<'PY'
import sys, wave
from pathlib import Path
for raw in Path(sys.argv[1]).glob("cond_*/*.raw"):
    with wave.open(str(raw.with_suffix(".wav")), "wb") as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(16000); w.writeframes(raw.read_bytes())
PY
"$W/apple_stt" "$W"/cond_clean/*.wav "$W"/cond_noisy/*.wav > "$W/apple_results.jsonl"
python3 "$E/compare.py" "$W"
