# Setup

This setup is a simplified version of the one in https://github.com/istio/tools/tree/master/perf/benchmark
Geared towards more research and less for CI.

Create 3 `n2-standard-16` node cluster:


```sh
# fill in GCLOUD_PROJECT, CLUSTER_NAME
gcloud beta container --project $GCLOUD_PROJECT clusters create $CLUSTER_NAME --zone "us-central1-c" --no-enable-basic-auth --cluster-version "1.21.10-gke.2000" --release-channel "regular" --machine-type "n2-standard-16" --image-type "COS_CONTAINERD" --disk-type "pd-standard" --disk-size "100" --metadata disable-legacy-endpoints=true --scopes "https://www.googleapis.com/auth/devstorage.read_only","https://www.googleapis.com/auth/logging.write","https://www.googleapis.com/auth/monitoring","https://www.googleapis.com/auth/servicecontrol","https://www.googleapis.com/auth/service.management.readonly","https://www.googleapis.com/auth/trace.append" --max-pods-per-node "110" --num-nodes "3" --logging=SYSTEM,WORKLOAD --monitoring=SYSTEM --enable-ip-alias --network "projects/solo-test-236622/global/networks/default" --subnetwork "projects/solo-test-236622/regions/us-central1/subnetworks/default" --no-enable-intra-node-visibility --default-max-pods-per-node "110" --no-enable-master-authorized-networks --addons HorizontalPodAutoscaling,HttpLoadBalancing,GcePersistentDiskCsiDriver --enable-autoupgrade --enable-autorepair --max-surge-upgrade 1 --max-unavailable-upgrade 0 --enable-shielded-nodes --node-locations "us-central1-c"
```

Or for existing cluster:
```sh
gcloud container clusters get-credentials $CLUSTER_NAME --project $GCLOUD_PROJECT --zone us-central1-c
```

Install istio 1.13, Disable L7 auto detection:

```sh
istioctl install -y -f - <<EOF
apiVersion: install.istio.io/v1alpha1
kind: IstioOperator
metadata:
  name: istio
  namespace: istio-system
spec:
  profile: minimal
  components:
    pilot:
      enabled: true
      k8s:
        env:
        - name: PILOT_ENABLE_PROTOCOL_SNIFFING_FOR_OUTBOUND
          value: "false"
        - name: PILOT_ENABLE_PROTOCOL_SNIFFING_FOR_INBOUND
          value: "false"
EOF
```

test ns with injection enabled:
```sh
kubectl create ns testing
kubectl label namespace testing istio-injection=enabled
```

Create the test rig:

```sh
kubectl -n testing apply -f load-test.yaml
```
Note that config above turns on mTLS for port 8080.

# Run some tests

## Tests with concurrency 1

```
# baseline, no sidecar (port 8077 is excluded outbound..)
kubectl --namespace testing exec deploy/fortioclient -c captured -- nighthawk_client --concurrency 1 --output-format json \
    --prefetch-connections --open-loop --experimental-h1-connection-reuse-strategy lru \
    --max-concurrent-streams 1 --connections 10 --rps 4000 --duration 60 \
      http://fortioserver.testing.svc.cluster.local:8077/ | tee out-uncaptured-1.json
# mtls
kubectl --namespace testing exec deploy/fortioclient -c captured -- nighthawk_client --concurrency 1 --output-format json \
    --prefetch-connections --open-loop --experimental-h1-connection-reuse-strategy lru \
    --max-concurrent-streams 1 --connections 10 --rps 4000 --duration 60 \
      http://fortioserver.testing.svc.cluster.local:8080/ | tee out-captured-mtls-1.json
# sidecar, no mtls
kubectl --namespace testing exec deploy/fortioclient -c captured -- nighthawk_client --concurrency 1 --output-format json \
    --prefetch-connections --open-loop --experimental-h1-connection-reuse-strategy lru \
    --max-concurrent-streams 1 --connections 10 --rps 4000 --duration 60 \
      http://fortioserver.testing.svc.cluster.local:8082/ | tee out-captured-1.json
```

See the p95:
```
jq '.results[] | select(.name == "global") .statistics[] | select(.id == "benchmark_http_client.latency_2xx")|.percentiles[]|select(.percentile == 0.95)' out-uncaptured.json
jq '.results[] | select(.name == "global") .statistics[] | select(.id == "benchmark_http_client.latency_2xx")|.percentiles[]|select(.percentile == 0.95)' out-captured-mtls.json
jq '.results[] | select(.name == "global") .statistics[] | select(.id == "benchmark_http_client.latency_2xx")|.percentiles[]|select(.percentile == 0.95)' out-captured.json
```

Results from my setup:
```
❯ jq '.results[].statistics[] | select(.id == "benchmark_http_client.latency_2xx")|.percentiles[]|select(.percentile == 0.95)' out-uncaptured.json

{
  "percentile": 0.95,
  "count": "379784",
  "duration": "0.000533727s"
}

❯ jq '.results[].statistics[] | select(.id == "benchmark_http_client.latency_2xx")|.percentiles[]|select(.percentile == 0.95)' out-captured.json

{
  "percentile": 0.95,
  "count": "379578",
  "duration": "0.000953375s"
}
```

## test without wasm filter

```
kubectl delete envoyfilter -n istio-system tcp-stats-filter-1.13
sleep 1
# mtls
kubectl --namespace testing exec deploy/fortioclient -c captured -- nighthawk_client --concurrency 1 --output-format json \
    --prefetch-connections --open-loop --experimental-h1-connection-reuse-strategy lru \
    --max-concurrent-streams 1 --connections 10 --rps 4000 --duration 100 \
      http://fortioserver.testing.svc.cluster.local:8080/ | tee out-captured-no-stats.json
```

Results from my setup:
```
❯ jq '.results[].statistics[] | select(.id == "benchmark_http_client.request_to_response")|.percentiles[]|select(.percentile == 0.95)' out-captured-no-stats.json

{
  "percentile": 0.95,
  "count": "379578",
  "duration": "0.000898079s"
}
```

## test with other parameters

Tried to make parameter as similar to https://github.com/jtaleric/cilium-testplan-proposal/ as I could 
understand it.
(this includes the TCP stats filter)

```
# baseline
kubectl --namespace testing exec deploy/fortioclient -c captured -- nighthawk_client --output-format json --duration 60 --rps 5000 --connections 10 --concurrency 16 -v info \
      http://fortioserver.testing.svc.cluster.local:8077/ | tee out-uncaptured-16.json

sleep 10

# sidecar
kubectl --namespace testing exec deploy/fortioclient -c captured -- nighthawk_client --output-format json --duration 60 --rps 5000 --connections 10 --concurrency 16 -v info \
      http://fortioserver.testing.svc.cluster.local:8082/ | tee out-captured-16.json

sleep 10

# mtls
kubectl --namespace testing exec deploy/fortioclient -c captured -- nighthawk_client --output-format json --duration 60 --rps 5000 --connections 10 --concurrency 16 -v info \
      http://fortioserver.testing.svc.cluster.local:8080/ | tee out-captured-mtls-16.json
```
# Results

Outputs (using `print_results.sh`):

```
❯ ./print_results.sh
out-uncaptured-16.json
P95: 0.000384863s
RQ_TOTAL: 3484112
DURATION: 60.000031071s
RPS: 58068.50

out-captured-16.json
P95: 0.000845791s
RQ_TOTAL: 2603079
DURATION: 60.000019103s
RPS: 43384.63

out-captured-mtls-16.json
P95: 0.000968511s
RQ_TOTAL: 2385268
DURATION: 60.000029482s
RPS: 39754.44
```

# Summary

Baseline latency is around 0.35 ms
Sidecar, TCP Only is around 0.85 ms
Sidecar+mTLS with TCP Only is around 1 ms