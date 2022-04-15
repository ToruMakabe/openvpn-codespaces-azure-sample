#!/bin/bash
set -eo pipefail

eval "$(jq -r '@sh "CA_CERT_PEM=\(.ca_cert_pem)"')"

CA_CERT_DER=$(echo "${CA_CERT_PEM}" | openssl x509 -outform der | base64 -w0)

jq -n --arg ca_cert_der "${CA_CERT_DER}" '{"ca_cert_der":$ca_cert_der}'
