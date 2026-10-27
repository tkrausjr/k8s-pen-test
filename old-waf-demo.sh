#!/bin/bash
# Written by Chris Grice -
# 
# In-cluster tests: reaching hackazon THROUGH Avi vs trying to go AROUND Avi.
# Run from the attacker jumpbox pod. Press Enter to advance each step.
#
# Test pods:
#   attacker/attacker - compromised POD workload in the VKS cluster
# Target:
#   music-store/music-store-1     - STRICT mTLS; AuthorizationPolicy hackazon-avi-only allows only
#
# Use environment variables if set, otherwise fallback to defaults
# Set these in the POD POD spec in Container section or in kubectl run command
VIP=${VIP:-172.16.2.52}
HOST=${HOST:-shop.avilb.broadcom.net}
SVC=${SVC:-http://hackazon.shop.svc.cluster.local}
TGT_NS=${TGT_NS:-default}
TGT_LABEL=${TGT_NS:-app=hackazon}

# These remain constructed from the variables above
U=https://$HOST
R="--resolve $HOST:80:$VIP"          # pins the hostname to the Avi VIP (no DNS record yet)
SQLI="search?searchString=%27%20OR%201%3D1--"

B=$(tput bold); C=$(tput setaf 6); Y=$(tput setaf 3); N=$(tput sgr0)
stage() { echo; echo "${B}${C}############ $* ############${N}"; }
step()  { echo; echo "${B}${C}== $1${N}"; shift; for l in "$@"; do echo "   $l"; done; }
run()   { echo "${B}\$ $*${N}"; eval "$@"; echo; }
expect(){ echo "${Y}   Expected: $*${N}"; read -rp "   [enter] " _; }

IP=$(kubectl -n ${TGT_NS} get pod -l app=hackazon -o jsonpath='{.items[0].status.podIP}')

# ---------------------------------------------------------------------------
stage "STAGE 1 - NOT THROUGH AVI (trying to skip the WAF and AVI)"
echo "   Each test tries to reach music-store without going through the Avi VIP."
echo "   If any of these worked, the WAF could be bypassed from inside the cluster."

step "2.1 Attacker pod(same Namespace) -> music-store by service name (plaintext)" \
     "The attacker sends plain HTTP to music-store Kubernetes Service on TCP 5000" \
     "vDefend does NOT allow the traffic, so it drops the connection."
run "curl -sS --max-time 3 $SVC/ 2>&1 | tail -1"
expect "connection reset (curl exit code 56) - VDEFEND RULE ?, no connection"

step "2.2 Rogue pod(different Namespace) -> music-store by service name (mTLS, wrong identity)" \
    "The attacker sends plain HTTP to music-store Kubernetes Service on TCP 5000" \
     "vDefend does NOT allow the traffic, so it drops the connection." \
run "kubectl -n rogue exec rogue -c rogue -- curl -sS --max-time 3 $SVC/; echo"
expect "RBAC: access denied (HTTP 403 from hackazon's sidecar)"

step "2.3 Rogue pod (different Namespace) -> music-store by service name, SQL injection (WAF bypass attempt)" \
     "The actual goal of going around Avi: send the attack where no WAF is inspecting." \
     "It is denied by vDefend before the request ever reaches the application."
run "kubectl -n rogue exec rogue -c rogue -- curl -s -o /dev/null -w 'HTTP %{http_code}\n' --max-time 3 \"$SVC/$SQLI\""
expect "HTTP 403 - the bypass fails; the only way in is through Avi"

#step "2.4 Attacker pod -> hackazon pod IP directly ($IP)" \
#     "Skips the Kubernetes service entirely and targets the pod IP." \
#     "Same result as 2.1: plaintext into a STRICT sidecar."
#run "kubectl -n attacker exec attacker -- curl -sS --max-time 5 http://$IP/ 2>&1 | tail -1"
#expect "connection reset (exit code 56)"

# NEED To SEE IF WE CAN GET THE NPL Address
#step "2.6 Attacker pod -> Avi's own backend address ($NPL)" \
#     "This is the NodePortLocal node:port the Avi SE uses to reach hackazon." \
#     "It is reachable on the network, but it lands on the same STRICT sidecar." \
#     "Without the mesh certificate AKO gave the SE, the connection is dropped."
#run "kubectl -n attacker exec attacker -- curl -sS --max-time 5 http://$NPL/ 2>&1 | tail -1"
#expect "connection reset (exit code 56) - even Avi's path is useless without Avi's identity"

# ---------------------------------------------------------------------------
stage "STAGE 2 - THROUGH AVI Ingress Controller AKO (the allowed path)"
echo "   In-cluster clients call the Avi VIP, just like external users."
echo "   Path: pod -> Avi VIP $VIP (WAF) -> as ako-sa -> music-store-1"

step "2.1 Attacker pod (outside the music-store Namespace) -> Avi VIP, normal request" \
     "A plain HTTP request to the music-store home page via Avi." \
     "Avi receives the request, the WAF finds nothing, and the SE opens to backend pool members" \
     "The access rule allows it."
run "kubectl -n rogue exec rogue -c rogue -- curl -s $R --max-time 3 -o /dev/null -w 'HTTP %{http_code}\n' $U/"
expect "HTTP 200 - legitimate traffic through Avi works, even from a pod with no mesh identity"

step "2.2 Attacker pod (inside the music-store Namespace)-> Avi VIP, and a SQL injection attack " \
     "Same path, but the request carries a classic SQL injection: ' OR 1=1--" \
     "Avi's WAF (System-WAF-Policy, OWASP CRS) inspects it and blocks it at the SE." \
     "The request never reaches our music-store-1 frontend POD."
run "curl -s $R --max-time 3 -o /dev/null -w 'HTTP %{http_code}\n' \"$U/$SQLI\""
expect "HTTP 403 from Avi - check the Avi UI: VS music-store-gw > Logs for the WAF hit"

step "2.4 Rogue pod -> Avi VIP, SQL injection" \
     "Being inside the mesh earns no special treatment at the front door."
run "kubectl -n rogue exec rogue -c rogue -- curl -s $R --max-time 3 -o /dev/null -w 'HTTP %{http_code}\n' \"$U/$SQLI\""
expect "HTTP 403 from Avi - everyone gets the WAF"



# ---------------------------------------------------------------------------
stage "SUMMARY"
echo "   Through Avi:     clean traffic allowed (200), attacks blocked by the WAF (403)"
echo "   Around Avi:      every path refused - no identity = reset, wrong identity = denied"
echo
echo "   ${B}No way around it (mTLS + identity), no way through it (Avi WAF).${N}"