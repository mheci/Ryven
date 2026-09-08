#!/usr/bin/env bash
# Sign a UKI EFI binary with the MOK/UKI signing key using sbsign.
set -euo pipefail
UKI_PATH="${1:?UKI path required}"
KEY="${UKI_SIGNING_KEY:?UKI_SIGNING_KEY env var must point to RSA private key}"
CERT="${UKI_SIGNING_CERT:-${KEY%.key}.crt}"
echo "Signing UKI ${UKI_PATH}"
sbsign --key "${KEY}" --cert "${CERT}" --output "${UKI_PATH}.signed" "${UKI_PATH}"
mv "${UKI_PATH}.signed" "${UKI_PATH}"
sbverify --cert "${CERT}" "${UKI_PATH}"
echo "UKI signed and verified."
