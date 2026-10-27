## k8s-pen-test — Avi WAF + vDefend Microsegmentation Demo

An attacker pod and a small probe script (`waf-connectivity-check.sh`) used to
demonstrate layered Kubernetes network security for the **music-store** app:
Avi (AKO) WAF at the ingress, and vDefend/Antrea microsegmentation inside the
cluster.

> **v0.6** — the probe script now ships as a ConfigMap mounted into the pod, for
> faster iteration (edit the script, recreate the pod — no image rebuild).

## What the probe tests

`waf-connectivity-check.sh` runs four checks from inside the pod:

| # | Target | Path | What it proves |
|---|--------|------|----------------|
| 1 | Pod IP (direct) | bypasses Service + Avi | reachable only if microsegmentation is off |
| 2 | In-cluster Service name | bypasses Avi | reachable only if microsegmentation is off |
| 3 | HTTPRoute FQDN via Avi | SQL injection | the WAF inspects and blocks it |
| 4 | HTTPRoute FQDN via Avi | clean request | the allowed ingress path |

## Prerequisites

- The **music-store** application is deployed to the `music-store` namespace.
- The layered security policies (3 tiers) are applied from
  [`k8s-vdefend-layered`](https://github.com/tkrausjr/k8s-vdefend-layered.git) —
  follow that repo's instructions to apply the microservice layered security policy.

---
## 0. Configure the attacker pod with your environment information by editing the attacker-pod.yaml
```bash
    env:
    - name: VIP
      value: "0.0.0.0"
    - name: HOST
      value: "metal-store.domain-name.zoo"
    - name: SVC
      value: "http://music-store-1-service.music-store.svc.cluster.local:5000"
    - name: TGT_NS
      value: "music-store"
    - name: TGT_LABEL
      value: "app=music-store-1"
    - name: PORT
      value: "5000"
    - name: SQLI
      value: "search?searchString=%27%20OR%201%3D1--"
```


## 1. Deploy the attacker pod

```bash
cd ~/sa-work/local-files/k8s-pen-test
k apply -f k8s/waf-demo-rbac.yaml      # ServiceAccount + bindings in music-store, once
k apply -f k8s/attacker-pod.yaml
```

Confirm the policies are in place:

```bash
k get acnp -A
```

## 2. Run the demo

The flow runs the probe three times — with policy enforced, with the baseline
deny removed, and with it restored — to show the default-deny controlling
microservice communication.

### Step A — Baseline: all security policies applied

```bash
k -n music-store exec -it pod/attacker -- /bin/bash
  ./waf-connectivity-check.sh
```

**Expected:**

| Test | Result | Why |
|------|--------|-----|
| 1 — Pod IP | no response (curl error 28) | dropped by `baseline-default-deny` |
| 2 — Service name | no response (curl error 28) | dropped by `baseline-default-deny` |
| 3 — FQDN via Avi (SQLi) | **HTTP 403** | blocked by the Avi WAF |
| 4 — FQDN via Avi (clean) | **HTTP 200** | allowed ingress path |

> Test 3 is always blocked by the WAF whether or not the in-cluster policies are
> present — the WAF sits at the Avi SE, in front of the app.

### Step B — Remove the baseline deny

Dropping the catch-all opens the two in-cluster paths that were being denied.

```bash
k delete acnp baseline-default-deny
#   clusternetworkpolicy.crd.antrea.io "baseline-default-deny" deleted

k -n music-store exec -it pod/attacker -- /bin/bash
  ./waf-connectivity-check.sh
```

**Expected:**

| Test | Result | Why |
|------|--------|-----|
| 1 — Pod IP | **HTTP 200** | direct pod access now permitted |
| 2 — Service name | **HTTP 200** | Service access now permitted |
| 3 — FQDN via Avi (SQLi) | **HTTP 403** | still blocked by the Avi WAF |
| 4 — FQDN via Avi (clean) | **HTTP 200** | allowed ingress path |

### Step C — Restore the baseline deny

Reapply the policy to showcase full control of microservice communication.

```bash
k apply -f ./k8s/baseline-default-deny.yaml
k get acnp

k -n music-store exec -it pod/attacker -- /bin/bash
  ./waf-connectivity-check.sh
```

**Expected:** back to the Step A results — tests 1 and 2 denied, test 3 → 403,
test 4 → 200.

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

---

## Testing the image against a local cluster (Colima)

```bash
colima status
k config use-context colima
#   Switched to context "colima".

k get po,svc
#   NAME                            READY   STATUS    RESTARTS      AGE
#   pod/web-demo-6994854496-9zm84   1/1     Running   8 (14d ago)   126d
#
#   NAME                     TYPE           CLUSTER-IP     EXTERNAL-IP    PORT(S)        AGE
#   service/kubernetes       ClusterIP      10.43.0.1      <none>         443/TCP        126d
#   service/web-service-lb   LoadBalancer   10.43.111.17   192.168.64.2   80:32747/TCP   126d
```

The nginx pod is exposed to the Mac via the external IP:

```bash
curl http://192.168.64.2
#   <!DOCTYPE html>
#   <html>
#   <head>
#   <title>Welcome to nginx!</title>
```

Label the local pod so the probe's selector finds it, then run the attacker pod:

```bash
k label po web-demo-6994854496-9zm84 app=hackazon --overwrite=true
#   pod/web-demo-6994854496-9zm84 labeled

# Option 1 — declarative
# Update the ENV in waf-demo-pods.yaml (Avi VIP, etc.) first.
k create ns attacker
k create ns rogue
k apply -f ./waf-demo-rbac.yaml
k apply -f ./waf-demo-pods.yaml

k exec -it attacker -n music-store -- /bin/bash
#   waf-demo-pod:/scripts# ./waf-demo.sh
```
