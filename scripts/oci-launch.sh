#!/usr/bin/env bash
# Launch an OCI Arm (A1) instance, retrying while the region is out of host capacity.
# Needs a configured OCI CLI (~/.oci/config). Only capacity errors are retried; anything else stops.
#
# Usage:
#   OCI_COMPARTMENT=ocid1.tenancy... OCI_SUBNET=ocid1.subnet... SSH_PUBKEY=~/.ssh/key.pub \
#     scripts/oci-launch.sh [name]
# Optional: OCPUS (2), MEMORY_GB (12), INTERVAL seconds between attempts (120), IMAGE_ID.
set -euo pipefail

name=${1:-exit-node}
: "${OCI_COMPARTMENT:?set OCI_COMPARTMENT (tenancy OCID for the root compartment)}"
: "${OCI_SUBNET:?set OCI_SUBNET (a public subnet OCID)}"
: "${SSH_PUBKEY:?set SSH_PUBKEY (path to the public key)}"
SSH_PUBKEY=${SSH_PUBKEY/#\~/$HOME}
[ -f "$SSH_PUBKEY" ] || { echo "no such file: $SSH_PUBKEY" >&2; exit 1; }
ocpus=${OCPUS:-2}
memory=${MEMORY_GB:-12}
interval=${INTERVAL:-120}
shape=VM.Standard.A1.Flex

ad=$(oci iam availability-domain list --compartment-id "$OCI_COMPARTMENT" \
    --query 'data[0].name' --raw-output)
image=${IMAGE_ID:-$(oci compute image list --compartment-id "$OCI_COMPARTMENT" \
    --operating-system "Canonical Ubuntu" --operating-system-version "24.04 Minimal aarch64" \
    --shape "$shape" --sort-by TIMECREATED --sort-order DESC --limit 1 \
    --query 'data[0].id' --raw-output)}
[ -n "$image" ] && [ "$image" != null ] || { echo "Ubuntu 24.04 Minimal aarch64 image not found; set IMAGE_ID" >&2; exit 1; }

echo "Launching $name: $shape ${ocpus} OCPU / ${memory} GB in $ad"
echo "Image: $image"
attempt=0
err=$(mktemp)
trap 'rm -f "$err"' EXIT
while :; do
    attempt=$((attempt + 1))
    # stdout = instance OCID only; the CLI's progress and error messages go to stderr.
    if instance=$(oci compute instance launch \
        --compartment-id "$OCI_COMPARTMENT" \
        --availability-domain "$ad" \
        --display-name "$name" \
        --shape "$shape" \
        --shape-config "{\"ocpus\": $ocpus, \"memoryInGBs\": $memory}" \
        --image-id "$image" \
        --subnet-id "$OCI_SUBNET" \
        --assign-public-ip true \
        --ssh-authorized-keys-file "$SSH_PUBKEY" \
        --instance-options '{"areLegacyImdsEndpointsDisabled": true}' \
        --availability-config '{"recoveryAction": "RESTORE_INSTANCE"}' \
        --wait-for-state RUNNING --max-wait-seconds 900 \
        --query 'data.id' --raw-output 2>"$err"); then
        break
    fi
    out=$(cat "$err")
    case $out in
        *"ut of host capacity"* | *"ut of capacity"*)
            echo "$(date '+%F %T') attempt $attempt: out of capacity, retrying in ${interval}s" ;;
        *TooManyRequests*)
            echo "$(date '+%F %T') attempt $attempt: rate limited, backing off"
            sleep "$interval" ;;
        *)
            echo "Launch failed (not a capacity error):" >&2
            echo "$out" >&2
            exit 1 ;;
    esac
    sleep "$interval"
done

echo "Created and running: $instance"
ip=$(oci compute instance list-vnics --instance-id "$instance" \
    --query 'data[0]."public-ip"' --raw-output)
echo "Running. Public IP: $ip"
echo "Test: ssh -i ${SSH_PUBKEY%.pub} ubuntu@$ip"
