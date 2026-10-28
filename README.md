## k8s-pen-test — Avi WAF + vDefend Microsegmentation Demo

An attacker pod and a small probe script (`connectivity-check.sh`) used to
demonstrate layered Kubernetes network security for any Kubernetes Web Application running on VCF with vDefend and Avi using
Avi (AKO) WAF for inbound traffic, and vDefend/Antrea microsegmentation inside the
cluster.

> **v0.6** — the probe script ships as a ConfigMap mounted into the pod, for
> faster iteration (edit the script, recreate the pod — no image rebuild). The
> pod runs `sleep infinity`, so you exec in and run the script on demand.

## Repo layout

```
k8s-pen-test/
├── connectivity-check.sh     # the probe script (source of truth)
├── Dockerfile                    # builds mytkrausjr/waf-demo
└── k8s/
    ├── attacker-pod.yaml         # attacker Pod + ConfigMap (embeds the script)
    └── attacker-rbac.yaml        # ServiceAccount waf-demo-sa + ClusterRole + bindings
```

## What the probe tests

`connectivity-check.sh` runs **five** checks from inside the pod. Each prints a
colored pass/fail verdict against its expected result:

| # | Target | Payload | Expected | Verdict mode |
|---|--------|---------|----------|--------------|
| 1 | In-cluster Pod IP (direct) | bypasses Service + Avi | **no response** (dropped) | `--deny` — no response = green, any HTTP = red |
| 2 | In-cluster Service name | bypasses Avi | **no response** (dropped) | `--deny` — no response = green, any HTTP = red |
| 3 | HTTPRoute FQDN via Avi | SQL injection | **HTTP 403** (WAF blocks) | `--expect 403` — 403 = green, else red |
| 4 | HTTPRoute FQDN via Avi | PHP injection (`php://filter`) | **HTTP 403** (WAF blocks) | `--expect 403` — 403 = green, else red |
| 5 | HTTPRoute FQDN via Avi | clean request | **HTTP 200** (allowed) | `--expect 200` — 200 = green, else red |

The attacks (3, 4) target the **root path** with the payload in a query string, so
when the WAF is **off** they return **200** (reached the app), not 403 — a clean
"not blocked" signal.

## Prerequisites

- The **music-store** or similar application is deployed to a Kubernetes namespace.
- The layered security policies (3 tiers) are applied from
  [`k8s-vdefend-layered`](https://github.com/tkrausjr/k8s-vdefend-layered.git) —
  follow that repo's instructions to apply the microservice layered security policy.
- The Avi WAF is attached to the `metal-store` HTTPRoute via an AKO **L7Rule**
  (`metal-store-waf`) referenced by an `ExtensionRef` filter — this is what makes
  tests 3 and 4 return 403.
- Avi WAF policy "System-WAF-Policy" is set to Enforcement Policy Mode.
- The Target Web Pod is Labeled so the probe's selector finds the Pods and can return its IP

```bash
k label po web-demo-1 app=music-store-1 --overwrite=true
#   pod/web-demo-1 labeled

```

---
## 0. Configure the attacker pod for your environment

Edit the container `env` in `k8s/attacker-pod.yaml`:

```yaml
    env:
    - name: VIP
      value: "0.0.0.0"                                   # Avi VIP the HTTPRoute FQDN resolves to
    - name: HOST
      value: "metal-store.domain-name.zoo"               # HTTPRoute FQDN
    - name: SVC
      value: "http://music-store-1-service.music-store.svc.cluster.local:5000"
    - name: TGT_NS
      value: "music-store"                               # namespace the target pod lives in
    - name: TGT_LABEL
      value: "app=music-store-1"                         # selector to find the pod for the pod-IP probe
    - name: PORT
      value: "5000"                                      # app port for the pod-IP probe
    - name: SQLI
      value: "?searchString=%27%20OR%201%3D1--"          # SQL injection payload (root-path query string)
    - name: PHPI
      value: "?file=php%3A%2F%2Ffilter%2Fconvert.base64-encode%2Fresource%3Dindex.php"   # PHP injection payload
```

## 1. Deploy the attacker pod

```bash
cd ~/sa-work/local-files/k8s-pen-test
k apply -f k8s/attacker-rbac.yaml      # ServiceAccount waf-demo-sa + bindings in music-store, once
k apply -f k8s/attacker-pod.yaml       # attacker Pod + connectivity-check ConfigMap
```

Remove the ACNP baseline policy and the WAF l7rule to show the vulnerabilities and how vDefend and Avi work better together:

```bash
k delete acnp music-store-baseline-default-deny.yaml
k delete l7rule metal-store-waf -n music-store
k get acnp -A
k get l7rule -n music-store
```

## 2. Run connectivity script on the attacker pod to show the applications response without WAF and vDefend

The flow runs the probe tests five times — without the WAF policy l7rule or ACNP baseline policy applied. Dropping the baseline catch-all opens the two in-cluster paths; deleting the L7Rule effectively detaches the WAF so the attacks reach the app.

### Step A — Baseline: No security policies or L7 WAF policies are applied

```bash
k -n music-store exec -it pod/attacker -- /bin/bash
  /scripts/connectivity-check.sh
```

**Expected:**

| Test | Result | Why |
|------|--------|-----|
| 1 — Pod IP | **HTTP 200** | direct pod access now permitted |
| 2 — Service name | **HTTP 200** | Service access now permitted |
| 3 — FQDN via Avi (SQLi) | **HTTP 200** | not blocked — payload reaches the app on the root path |
| 4 — FQDN via Avi (PHP) | **HTTP 200** | not blocked — payload reaches the app on the root path |
| 5 — FQDN via Avi (clean) | **HTTP 200** | allowed ingress path |


### Step B — Apply the baseline Antrea Cluster Network Policy(ACNP) baseline and the Avi WAF L7rule


```bash
# Add back the ACNP catch-all baseline rule
k apply -f /github/k8s-vdefend-layered/k8s/baseline-default-deny.yaml
    clusternetworkpolicy.crd.antrea.io "baseline-default-deny" created

# Add back the AKO L7Rule (attaches the Avi WAF)
k apply -f /github/k8s-vdefend-layered/k8s/metal-store-waf-l7rule.yaml
    l7rule.ako.vmware.com/metal-store-waf created

k get acnp -A
k get l7rule -n music-store

k -n music-store exec -it pod/attacker -- /bin/bash
  /scripts/connectivity-check.sh
```

**Expected:**

| Test | Result | Why |
|------|--------|-----|
| 1 — Pod IP | no response timeout/drop | dropped by `baseline-default-deny` so you cant bypass Avi WAF|
| 2 — Service name | no response timeout/drop | dropped by `baseline-default-deny` so you cant bypass Avi WAF|
| 3 — FQDN via Avi (SQLi) | **HTTP 403** | blocked by the Avi WAF |
| 4 — FQDN via Avi (PHP) | **HTTP 403** | blocked by the Avi WAF |
| 5 — FQDN via Avi (clean) | **HTTP 200** | allowed ingress path |




---

## Building the image (multi-arch on macOS)

The nodes are amd64, so the image must be built for `linux/amd64`. On an Apple
Silicon Mac, build inside an x86 Lima VM.

### One-time setup

```bash
brew install lima     # (already done)
brew install qemu
limactl start --arch x86_64 --name ubuntu-x86 template:ubuntu-lts
limactl list
#   NAME        STATUS     SSH                VMTYPE    ARCH       CPUS   MEMORY   DISK     DIR
#   amd64-vm    Running    127.0.0.1:54339    vz        aarch64    4      4GiB     100GiB   ~/.lima/amd64-vm
```

### Build and push

```bash
limactl shell ubuntu-x86
#   lima@lima-amd64-vm:/Users/USER/scratch/k8s-pen-test$

sudo apt install docker.io
sudo su
cd /Users/USER/scratch/k8s-pen-test/

docker login -u mytkrausjr        # paste your PAT at the password prompt

docker build --platform linux/amd64 -t mytkrausjr/waf-demo:v0.6 .
docker push mytkrausjr/waf-demo:v0.6
```



