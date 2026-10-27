# v0.6 Updated with script as Configmap for easier faster iteration and testing
# Run the pod in target namespace.
cd ~/sa-work/local-files/k8s-pen-test
k apply -f k8s/waf-demo-rbac.yaml            # SA + bindings in music-store, once
k apply -f k8s/attacker-pod.yaml
k -n music-store exec -it pod/attacker -- /bin/bash
    ./waf-connectivity-check.sh

# Run through the demonstration.

Assumes you have deployed the music-store application to the music-store K8s Namespace
Assumes you have cloned the k8s-vdefend-layered repo locally and applied the security policies (3 Tiers)
Follow the instructions in the repo to apply the microservice layered sec policy.
https://github.com/tkrausjr/k8s-vdefend-layered.git

k get acnp -A

When we remove the ACNP baseline Deny All Traffic is allowed through from all 4 tests.

k delete acnp baseline-default-deny            
    clusternetworkpolicy.crd.antrea.io "baseline-default-deny" deleted

k -n music-store exec -it pod/attacker -- /bin/bash
    ./waf-connectivity-check.sh

NOW all 4 curl tests come back with an HTTP response code as they were able to get through directly to the POD, SVC, and HTTPROUTE. Expecatations when baseline policy is removed. Test-1 - 200, Test-2 - 200,  Test-3 - Responds with 403(Blocked by Avi WAF) and Test-4 responds with 200 should always respond with 200 when all rules are in place or when they are not..

Now put back the baseline policy to showcase the complete control of microservice communication

k apply -f ./k8s/baseline-default-deny.yaml
k get acnp

k -n music-store exec -it pod/attacker -- /bin/bash
    ./waf-connectivity-check.sh

Expectations when Security policies are applied. No response from Test-1, Test-2 (Curl error 28) and Test-3 Responds with 403(Blocked by Avi WAF) and Test-4 responds with 200 should always respond with 200 when all rules are in place or when they are not..

---

## OSX build the Image
- brew install lima (DONE ALREADY)
- brew install qemu
- limactl start --arch x86_64 --name ubuntu-x86 template:ubuntu-lts 
- limactl list
	- NAME        STATUS     SSH                VMTYPE    ARCH       CPUS    MEMORY    DISK      DIR
	- amd64-vm    Running    127.0.0.1:54339    vz        aarch64    4       4GiB      100GiB    ~/.lima/amd64-vm

- limactl shell ubuntu-x86
	-  lima@lima-amd64-vm:/Users/USER/scratch/k8s-pen-test$

-  sudo apt install docker.io
-  sudo su

cd /Users/USER/scratch/k8s-pen-test/

sudo su
# Command syntax below to build multi-platform version.

docker login -u mytkrausjr
COPY PAT and PASTE into Password prompt

docker build --platform linux/amd64 -t mytkrausjr/waf-demo:v0.6 .
docker push mytkrausjr/waf-demo:v0.6  

## Test against local K8s cluster running under Colima
colima status
k config use-context colima
    Switched to context "colima".

k get po,svc
    NAME                            READY   STATUS    RESTARTS      AGE
    pod/web-demo-6994854496-9zm84   1/1     Running   8 (14d ago)   126d

    NAME                     TYPE           CLUSTER-IP     EXTERNAL-IP    PORT(S)        AGE
    service/kubernetes       ClusterIP      10.43.0.1      <none>         443/TCP        126d
    service/web-service-lb   LoadBalancer   10.43.111.17   192.168.64.2   80:32747/TCP   126d
# Nginx pod exposed to the MAC via External IP
# Test 
curl http://192.168.64.2
    <!DOCTYPE html>
    <html>
    <head>
    <title>Welcome to nginx!</title>

# Test our Container against our local K8s cluster.

k label po web-demo-6994854496-9zm84 app=hackazon --overwrite=true
    pod/web-demo-6994854496-9zm84 labeled


# OPTION 1 - Declarative
# Update waf-demo-pods.yaml ENV with correct AVI VIP etc. settings.
k create ns attacker
k create ns rogue
k apply -f ./waf-demo-rbac.yaml
k apply -f ./waf-demo-pods.yaml

k exec -it attacker -n music-store -- /bin/bash
    waf-demo-pod:/scripts# ./waf-demo.sh


