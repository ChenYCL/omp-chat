#!/bin/bash
# Benchmark: how long the phone terminal waits for the first byte of a
# long-running remote command (Host RPC exec vs exec + exec.poll streaming).
# Hermetic: runs HostExecutor in-process, no network, no installed app.
set -euo pipefail
cd "$(dirname "$0")/Packages/OMPKit"

out=$(OMP_BENCH=1 swift test --jobs 4 --filter StreamingLatencyBenchmark 2>&1) || {
    echo "$out" | grep -E "error:|failed" | head -20
    exit 1
}
metrics=$(echo "$out" | grep -E '^METRIC ' || true)
if [ -z "$metrics" ]; then
    echo "$out" | tail -20
    echo "no METRIC lines (benchmark skipped or crashed)" >&2
    exit 1
fi
echo "$metrics"
