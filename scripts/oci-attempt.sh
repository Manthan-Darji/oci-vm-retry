#!/bin/bash
# oci-attempt.sh — ONE idempotent launch attempt for the money-machine VM.
# Used by GitHub Actions (one attempt per scheduled run).
# Exit 0 always: out-of-capacity / rate-limit are expected, not failures.
set -u

COMP="ocid1.compartment.oc1..aaaaaaaablf7mvs42qxr24nmbicnvjr7kssufuhqv2btswizykv5xvoxz4eq"
AD="PdbV:AP-HYDERABAD-1-AD-1"
SHAPE="VM.Standard.A1.Flex"
SHAPECFG='{"ocpus":2,"memoryInGBs":12}'
IMAGE="ocid1.image.oc1.ap-hyderabad-1.aaaaaaaaucbtrhfdq3kdrfn2x2tz73uc3wgutd6k7ibt4eq7rh33gr47ltpa"
SUBNET="ocid1.subnet.oc1.ap-hyderabad-1.aaaaaaaasmgtmiy3hlkdo34az65slb2wwdu6g62epnvgnb6cuxz7rzwbw5vq"
SSHPUB="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINaBZjCx2Q1txVKJF6Kmj37Gim+aXmWSgqR6eqUsuUZ3 money-machine"
META=$(printf '{"ssh_authorized_keys":"%s"}' "$SSHPUB")

# 1. Idempotency: only skip if the real money-machine (A1) already exists.
# interim-micro is a separate box and must NOT stop the A1 hunt.
EXISTING_JSON=$(oci compute instance list --compartment-id "$COMP" 2>/dev/null)
EXISTING_OCID=$(printf '%s' "$EXISTING_JSON" | grep -B2 '"display-name": "money-machine"' | grep -o '"id": "ocid1.instance[^"]*"' | head -1 | cut -d'"' -f4)
if [ -n "$EXISTING_OCID" ]; then
  echo "SKIP: money-machine already exists: $EXISTING_OCID"
  exit 0
fi

# 2. Single launch attempt.
OUT=$(oci compute instance launch \
  --compartment-id "$COMP" \
  --availability-domain "$AD" \
  --shape "$SHAPE" \
  --shape-config "$SHAPECFG" \
  --image-id "$IMAGE" \
  --subnet-id "$SUBNET" \
  --assign-public-ip true \
  --boot-volume-size-in-gbs 100 \
  --display-name money-machine \
  --metadata "$META" 2>&1)

# 3. Classify.
if echo "$OUT" | grep -q "Out of host capacity"; then
  echo "RESULT: out-of-capacity (will retry next run)"
  exit 0
elif echo "$OUT" | grep -qi "TooManyRequests"; then
  echo "RESULT: rate-limited (will retry next run)"
  exit 0
elif echo "$OUT" | grep -q "ocid1.instance"; then
  NEWID=$(printf '%s' "$OUT" | grep -o '"id": "ocid1.instance[^"]*"' | head -1 | cut -d'"' -f4)
  echo "RESULT: LAUNCHED $NEWID"
  exit 0
else
  echo "RESULT: other: $(printf '%s' "$OUT" | tr '\n' ' ' | head -c 300)"
  exit 0
fi
