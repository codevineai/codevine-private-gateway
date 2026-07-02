#!/bin/sh
# Cert-validation bootstrap callback (Terraform `external` data source program).
#
# Reads a JSON object on stdin (the data.external `query`), POSTs the ACM
# wildcard-cert validation record to the CodeVine control plane so it can add the
# CNAME to the {domain} zone it owns, and prints a JSON object on stdout.
#
# Auth: the registration_secret is sent as a bearer credential over TLS. It is a
# limited-use, single-purpose key (identifier + password in one), used only for
# bootstrap (register + this callback). There is nothing to sign and no pod_id —
# the control plane finds the pod by the secret. See
# docs/engineering-specs/unified-gateway-architecture.html (§6) in the codevine
# repo for the contract.
#
# Host deps: sh + curl only (no jq). Terraform's external protocol requires:
#   - stdin  = a flat JSON object of strings (the `query`)
#   - stdout = a flat JSON object of strings (the `result`)
# A non-zero exit (or non-JSON stdout) fails the apply, which is what we want if
# the control plane rejects the secret or is unreachable.

set -eu

# --- read stdin (the query JSON) -------------------------------------------
# Values are simple strings with no embedded quotes (URLs, hostnames, a base64url
# secret, an ACM CNAME). Extract each with a minimal sed parser keyed on the
# field name — avoids a jq dependency.
INPUT="$(cat)"

field() {
  # $1 = key name. Prints the string value for "key":"value".
  printf '%s' "$INPUT" | sed -n 's/.*"'"$1"'"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p'
}

CONTROL_PLANE_URL="$(field control_plane_url)"
REGISTRATION_SECRET="$(field registration_secret)"
RECORD_NAME="$(field record_name)"
RECORD_VALUE="$(field record_value)"
REGION="$(field region)"

if [ -z "$CONTROL_PLANE_URL" ] || [ -z "$REGISTRATION_SECRET" ] || [ -z "$RECORD_NAME" ] || [ -z "$RECORD_VALUE" ]; then
  echo "cert-validation-callback: missing required input(s)" >&2
  exit 1
fi

URL="${CONTROL_PLANE_URL%/}/api/internal/gateway/pods/cert-validation"

# --- build request body -----------------------------------------------------
BODY=$(cat <<JSON
{"validation_records":[{"region":"${REGION}","name":"${RECORD_NAME}","type":"CNAME","value":"${RECORD_VALUE}"}]}
JSON
)

# --- POST -------------------------------------------------------------------
# -s silent, -S show errors, -f fail (non-2xx -> non-zero exit), capture body.
HTTP_BODY="$(
  curl -sSf \
    -X POST "$URL" \
    -H "Authorization: Bearer ${REGISTRATION_SECRET}" \
    -H "Content-Type: application/json" \
    --data "$BODY" \
    2> /tmp/cert-validation-callback.err
)" || {
  echo "cert-validation-callback: POST to $URL failed: $(cat /tmp/cert-validation-callback.err 2>/dev/null)" >&2
  exit 1
}

# --- emit Terraform external result (flat JSON of strings) ------------------
# We don't parse the response; success = the 2xx that curl -f already enforced.
printf '{"status":"ok","posted_record":"%s"}\n' "$RECORD_NAME"
