#!/usr/bin/env bash
# Keeps trying to create the Oracle Cloud VM "jobfeed-db" until capacity is available.
# Config comes only from env vars (see README). Secrets are never printed.
set -euo pipefail

: "${OCI_TENANCY_OCID:?}" "${OCI_USER_OCID:?}" "${OCI_FINGERPRINT:?}" "${OCI_PRIVATE_KEY:?}"
: "${OCI_REGION:?}" "${OCI_COMPARTMENT_OCID:?}" "${OCI_SUBNET_OCID:?}" "${SSH_PUBLIC_KEY:?}"

NAME="jobfeed-db"
SHAPE="VM.Standard.A1.Flex"
OCPUS=2
MEMORY_GB=12
BOOT_GB=100
BOOT_VPUS=10
MAX_ATTEMPTS="${MAX_ATTEMPTS:-5}"
RETRY_INTERVAL="${RETRY_INTERVAL:-20}"

WORK="$(mktemp -d)"
# Windows (Git Bash): native OCI CLI needs a Windows-style path
if command -v cygpath >/dev/null 2>&1; then WORK="$(cygpath -m "$WORK")"; fi
trap 'rm -rf "$WORK"' EXIT
umask 077

printf '%s\n' "$OCI_PRIVATE_KEY" > "$WORK/key.pem"
printf '%s\n' "$SSH_PUBLIC_KEY" > "$WORK/ssh.pub"
cat > "$WORK/config" <<CFG
[DEFAULT]
user=$OCI_USER_OCID
fingerprint=$OCI_FINGERPRINT
tenancy=$OCI_TENANCY_OCID
region=$OCI_REGION
key_file=$WORK/key.pem
CFG
export OCI_CLI_CONFIG_FILE="$WORK/config"
export OCI_CLI_SUPPRESS_FILE_PERMISSIONS_WARNING=True
export SUPPRESS_LABEL_WARNING=True

# JMESPath --raw-output prints "null" for no match; normalise to empty.
clean() { local v; v="$(tr -d '\r\n"' <<<"$1")"; [ "$v" = "null" ] && v=""; printf '%s' "$v"; }

# Run an oci command, abort the script if it fails, print the cleaned result.
oci_q() {
  local o
  o="$("$@")" || { echo "ERROR: oci command failed: ${*:1:3}" >&2; exit 1; }
  clean "$o"
}

public_ip() {
  oci_q oci compute instance list-vnics --instance-id "$1" --query 'data[0]."public-ip"' --raw-output
}

# Count every failed launch attempt by error code in keep-going.json (counts only, no error text).
record_error() {
  local py; py="$(command -v python3 || command -v python || true)"
  if [ -z "$py" ]; then echo "WARN: python not found, not recording error count" >&2; return 0; fi
  printf '%s' "$1" | "$py" "$(dirname "${BASH_SOURCE[0]}")/record_error.py" "${KEEP_GOING_FILE:-keep-going.json}" \
    || echo "WARN: could not update keep-going.json" >&2
}

# Marker file the workflow uses to stop retrying. Only non-sensitive facts: no OCIDs, no IP, no keys.
write_marker() {
  local f="${MARKER_FILE:-vm-created.json}"
  [ -f "$f" ] && return 0
  cat > "$f" <<JSON
{
  "displayName": "$NAME",
  "shape": "$SHAPE",
  "ocpus": $OCPUS,
  "memoryGb": $MEMORY_GB,
  "bootVolumeGb": $BOOT_GB,
  "region": "$OCI_REGION",
  "createdAt": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
JSON
  echo "Wrote $f"
}

report() {
  write_marker
  local ip; ip="$(public_ip "$1")"
  echo "Instance $NAME ready. Public IP: ${ip:-<none yet>}"
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    echo "VM \`$NAME\` public IP: \`${ip}\`" >> "$GITHUB_STEP_SUMMARY"
  fi
}

# 1. Already exists?
existing="$(oci_q oci compute instance list -c "$OCI_COMPARTMENT_OCID" --display-name "$NAME" \
  --query 'data[?"lifecycle-state"==`RUNNING` || "lifecycle-state"==`PROVISIONING`].id | [0]' --raw-output)"
if [ -n "$existing" ]; then
  echo "Instance $NAME already exists."
  report "$existing"
  exit 0
fi

# 2. Look up AD and latest Ubuntu 24.04 aarch64 image
AD="$(oci_q oci iam availability-domain list -c "$OCI_TENANCY_OCID" --query 'data[0].name' --raw-output)"
IMAGE="$(oci_q oci compute image list -c "$OCI_COMPARTMENT_OCID" --operating-system "Canonical Ubuntu" \
  --operating-system-version "24.04" --shape "$SHAPE" --sort-by TIMECREATED --sort-order DESC \
  --query 'data[0].id' --raw-output)"
[ -n "$AD" ] || { echo "ERROR: could not read availability domain" >&2; exit 1; }
[ -n "$IMAGE" ] || { echo "ERROR: no Ubuntu 24.04 image found for $SHAPE" >&2; exit 1; }
echo "AD: $AD"
echo "Image: $IMAGE"

# 3. Launch with retries
for ((i = 1; i <= MAX_ATTEMPTS; i++)); do
  echo "Attempt $i/$MAX_ATTEMPTS..."
  if out="$(oci compute instance launch \
      --availability-domain "$AD" \
      --compartment-id "$OCI_COMPARTMENT_OCID" \
      --subnet-id "$OCI_SUBNET_OCID" \
      --source-details "{\"sourceType\":\"image\",\"imageId\":\"$IMAGE\",\"bootVolumeSizeInGBs\":$BOOT_GB,\"bootVolumeVpusPerGB\":$BOOT_VPUS}" \
      --shape "$SHAPE" \
      --shape-config "{\"ocpus\":$OCPUS,\"memoryInGBs\":$MEMORY_GB}" \
      --display-name "$NAME" \
      --assign-public-ip true \
      --ssh-authorized-keys-file "$WORK/ssh.pub" \
      --query 'data.id' --raw-output 2>&1)"; then
    id="$(clean "$out")"
    echo "Launched $id, waiting for RUNNING..."
    oci compute instance get --instance-id "$id" --wait-for-state RUNNING --max-wait-seconds 600 >/dev/null
    if [ -n "${GITHUB_ACTIONS:-}" ]; then echo "::notice::VM $NAME created - disable this workflow now"; fi
    report "$id"
    exit 0
  fi
  record_error "$out"
  if grep -qiE "out of host capacity|TooManyRequests" <<<"$out"; then
    echo "Out of host capacity (or rate limited)."
    if [ "$i" -lt "$MAX_ATTEMPTS" ]; then sleep "$RETRY_INTERVAL"; fi
  else
    echo "ERROR: launch failed:" >&2
    echo "$out" >&2
    exit 1
  fi
done

echo "No capacity after $MAX_ATTEMPTS attempts; will try again next run."
exit 0
