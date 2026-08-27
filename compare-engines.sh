#!/bin/bash
# Extracts what each build actually DELIVERED (not partials) so runs can be diffed.
for f in /tmp/voicepilot_debug.log /tmp/voicepilot_next_debug.log; do
    [ -f "$f" ] || continue
    echo "=============================================================="
    echo "$f"
    echo "--------------------------------------------------------------"
    grep -E "engine = |deliver\(|\[Analyzer\] deliver|\[Legacy\] deliver|\[Speech\] deliver|dropped duplicate" "$f" \
      | sed -E 's/^[0-9-]+ //' || echo "(nothing delivered yet)"
done
echo "=============================================================="
echo "Analyzer finalization detail (last 15):"
grep -E "\[Analyzer\] result" /tmp/voicepilot_next_debug.log 2>/dev/null | tail -15 || echo "(none)"
