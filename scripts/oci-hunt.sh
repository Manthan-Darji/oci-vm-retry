#!/bin/bash
# oci-hunt.sh — GitHub Actions requester for the Oracle A1 slot.
# Parameterized by TARGET: "big" = money-machine (2 OCPU / 12GB),
#                          "mini" = money-machine-mini (1 OCPU / 6GB).
# Runs a bounded loop (BUDGET_SECS) inside one Actions job, then exits 0 so
# the next scheduled run continues seamlessly. GitHub cannot think, so every
# failure mode is handled explicitly below:
#   already exists (any live state) -> SKIP, exit 0
#   launched                        -> LAUNCHED, exit 0
#   out of host capacity            -> wait gap, retry
#   TooManyRequests (429)           -> gap += 15s (cap 120s), retry
#   LimitExceeded / QuotaExceeded   -> long wait (300s), force re-check, retry
#   auth / config / invalid shape   -> 3 consecutive = broken setup, exit 1 (red run)
#   empty output / network / other  -> 15 consecutive = exit 1, else wait + retry
#   budget exhausted                -> exit 0, next run continues
#   SIGTERM (Actions timeout/cancel)-> log and exit 0
# Pacing: base gap 30s per target; the two jobs are offset 15s by the
# workflow, so requests interleave BIG, MINI, BIG, MINI every 15s.
set -u

TARGET="${TARGET:?TARGET must be big or mini}"
BUDGET_SECS="${BUDGET_SECS:-3300}"
INITIAL_DELAY="${INITIAL_DELAY:-0}"
GAP_MIN=30
GAP_MAX=120
GAP_STEP=15

COMP="ocid1.compartment.oc1..aaaaaaaablf7mvs42qxr24nmbicnvjr7kssufuhqv2btswizykv5xvoxz4eq"
AD="PdbV:AP-HYDERABAD-1-AD-1"
SHAPE="VM.Standard.A1.Flex"
IMAGE="ocid1.image.oc1.ap-hyderabad-1.aaaaaaaaucbtrhfdq3kdrfn2x2tz73uc3wgutd6k7ibt4eq7rh33gr47ltpa"
SUBNET="ocid1.subnet.oc1.ap-hyderabad-1.aaaaaaaasmgtmiy3hlkdo34az65slb2wwdu6g62epnvgnb6cuxz7rzwbw5vq"
SSHPUB="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINaBZjCx2Q1txVKJF6Kmj37Gim+aXmWSgqR6eqUsuUZ3 money-machine"

if [ "$TARGET" = "big" ]; then
  NAME="money-machine"
  CFG='{"ocpus":2,"memoryInGBs":12}'
  BOOTGB=100
else
  NAME="money-machine-mini"
  CFG='{"ocpus":1,"memoryInGBs":6}'
  BOOTGB=50
fi
META=$(printf '{"ssh_authorized_keys":"%s"}' "$SSHPUB")

ts() { date -u +%FT%TZ; }
log() { echo "[$(ts)] [$TARGET] $*"; }

trap 'log "STOPPED (signal) after $n attempts, exiting clean"; exit 0' TERM INT

command -v oci >/dev/null 2>&1 || { log "FATAL: oci CLI not installed"; exit 1; }

# Returns 0 and prints the OCID if a live (non-terminated) instance with our
# display-name exists. Any other poller may have won it; never duplicate.
exists_ocid() {
  local EJ
  EJ=$(oci compute instance list --compartment-id "$COMP" 2>/dev/null) || return 1
  [ -n "$EJ" ] || return 1
  printf '%s' "$EJ" | python3 -c "
import json,sys
try:
  for i in json.load(sys.stdin)['data']:
    if i.get('display-name')=='$NAME' and i.get('lifecycle-state') not in ('TERMINATED','TERMINATING'):
        print(i['id']); break
except Exception:
  pass
" 2>/dev/null
}

if [ "$INITIAL_DELAY" -gt 0 ]; then
  log "initial offset ${INITIAL_DELAY}s (interleave with the other requester)"
  sleep "$INITIAL_DELAY"
fi

START=$(date +%s)
gap=$GAP_MIN
n=0
auth_fails=0
other_fails=0

while :; do
  ELAPSED=$(( $(date +%s) - START ))
  if [ "$ELAPSED" -ge "$BUDGET_SECS" ]; then
    log "budget ${BUDGET_SECS}s exhausted after $n attempts, exiting clean; next run continues"
    exit 0
  fi
  n=$((n+1))

  # Anti-duplicate check: at start, every 5th attempt, and after limit errors.
  if [ "$n" -eq 1 ] || [ $((n % 5)) -eq 0 ] || [ "${FORCE_CHECK:-0}" = "1" ]; then
    FORCE_CHECK=0
    FOUND=$(exists_ocid)
    if [ -n "$FOUND" ]; then
      log "SKIP: $NAME already exists: $FOUND (won by another poller)"
      exit 0
    fi
  fi

  OUT=$(oci compute instance launch \
    --compartment-id "$COMP" \
    --availability-domain "$AD" \
    --shape "$SHAPE" \
    --shape-config "$CFG" \
    --image-id "$IMAGE" \
    --subnet-id "$SUBNET" \
    --assign-public-ip true \
    --boot-volume-size-in-gbs "$BOOTGB" \
    --display-name "$NAME" \
    --metadata "$META" 2>&1)
  RC=$?

  if printf '%s' "$OUT" | grep -q '"lifecycle-state"\|ocid1.instance'; then
    NEWID=$(printf '%s' "$OUT" | grep -o '"id": "ocid1.instance[^"]*"' | head -1 | cut -d'"' -f4)
    log "LAUNCHED $NAME $NEWID on attempt $n"
    exit 0
  elif printf '%s' "$OUT" | grep -q "Out of host capacity"; then
    auth_fails=0; other_fails=0
    gap=$(( gap > GAP_MIN ? gap - GAP_STEP : GAP_MIN ))
    log "attempt $n: out of host capacity, sleeping ${gap}s"
    sleep "$gap"
  elif printf '%s' "$OUT" | grep -qi "TooManyRequests"; then
    auth_fails=0; other_fails=0
    gap=$(( gap + GAP_STEP > GAP_MAX ? GAP_MAX : gap + GAP_STEP ))
    log "attempt $n: RATE LIMITED, gap increased to ${gap}s"
    sleep "$gap"
  elif printf '%s' "$OUT" | grep -qiE "LimitExceeded|QuotaExceeded"; then
    auth_fails=0; other_fails=0
    FORCE_CHECK=1
    log "attempt $n: tenancy limit/quota hit, sleeping 300s then re-checking"
    sleep 300
  elif printf '%s' "$OUT" | grep -qiE "NotAuthenticated|InvalidKey|fingerprint|Could not find config|NotAuthorized|InvalidParameter|InvalidShape|ShapeNotFound|IncorrectState"; then
    auth_fails=$((auth_fails+1)); other_fails=0
    log "attempt $n: CONFIG/AUTH error ($auth_fails/3): $(printf '%s' "$OUT" | tr '\n' ' ' | head -c 200)"
    if [ "$auth_fails" -ge 3 ]; then
      log "FATAL: setup looks broken (auth/config/shape). Failing the run so it shows red."
      exit 1
    fi
    sleep "$gap"
  else
    other_fails=$((other_fails+1)); auth_fails=0
    log "attempt $n: transient/other error ($other_fails/15), rc=$RC: $(printf '%s' "$OUT" | tr '\n' ' ' | head -c 200)"
    if [ "$other_fails" -ge 15 ]; then
      log "FATAL: 15 consecutive unexplained failures. Failing the run for visibility."
      exit 1
    fi
    gap=$(( gap > GAP_MIN ? gap - GAP_STEP : GAP_MIN ))
    sleep "$gap"
  fi
done
