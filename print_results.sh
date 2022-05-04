#!/bin/bash

for f in $(ls -tr out*.json); do
    echo $f
    P95=$(jq -r '.results[] | select(.name == "global") | .statistics[] | select(.id == "benchmark_http_client.latency_2xx")|.percentiles[]|select(.percentile == 0.95)|.duration' $f)
    RQ_TOTAL=$(jq -r '.results[] | select(.name == "global") | .counters[] | select(.name == "upstream_rq_total")|.value' $f)
    DURATION=$(jq -r '.results[] | select(.name == "global") | .execution_duration' $f)
    
    # remove s suffix from duration, ans calc RPS.
    RPS=$(echo "scale=2; $RQ_TOTAL / ${DURATION%s}" | bc)
    
    echo "P95: $P95"
    echo "RQ_TOTAL: $RQ_TOTAL"
    echo "DURATION: $DURATION"
    echo "RPS: $RPS"

    echo
done