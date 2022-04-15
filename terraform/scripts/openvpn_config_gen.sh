#!/bin/bash
set -eo pipefail

eval "$(jq -r '@sh "VPNGW_ID=\(.vpngw_id) DNS_FORWARDER_IP=\(.dns_forwarder_ip) CLIENT_KEY=\(.client_key_pem) CLIENT_CERT=\(.client_cert_pem)"')"

DHCP_OPTIONS=$(cat ./config/openvpn/dhcp_options)
DHCP_OPTIONS="${DHCP_OPTIONS//$'\n'/\\n}"
DNS_SCRIPT=$(cat ./config/openvpn/dns_script)
DNS_SCRIPT="${DNS_SCRIPT//$'\n'/\\n}"
DNS_SCRIPT_SYSTEMD_RESOLVED=$(cat ./config/openvpn/dns_script_systemd_resolved)
DNS_SCRIPT_SYSTEMD_RESOLVED="${DNS_SCRIPT_SYSTEMD_RESOLVED//$'\n'/\\n}"
CLIENT_CERT="${CLIENT_CERT//$'\n'/\\n}"
CLIENT_KEY="${CLIENT_KEY//$'\n'/\\n}"

CONFIG_URL=$(az network vnet-gateway vpn-client generate --ids "${VPNGW_ID}" -o tsv)
wget -q "${CONFIG_URL}" -O "vpnconfig.zip"
unzip -oq "vpnconfig.zip" -d "./vpnconftemp"|| true
CONFIG_FILE="./vpnconftemp/OpenVPN/vpnconfig_cert.ovpn"
CONFIG_FILE_SYSTEMD_RESOLVED="./vpnconftemp/OpenVPN/vpnconfig_cert_systemd_resolved.ovpn"
cp "${CONFIG_FILE}" "${CONFIG_FILE_SYSTEMD_RESOLVED}"

sed -i "1i ${DNS_SCRIPT}" ${CONFIG_FILE}
sed -i "1i ${DHCP_OPTIONS}" ${CONFIG_FILE}
sed -i "1i dhcp-option DNS ${DNS_FORWARDER_IP}" ${CONFIG_FILE}
sed -i "s~\$CLIENTCERTIFICATE~${CLIENT_CERT}~" ${CONFIG_FILE}
sed -i "s~\$PRIVATEKEY~${CLIENT_KEY}~g" ${CONFIG_FILE}

sed -i "1i ${DNS_SCRIPT_SYSTEMD_RESOLVED}" ${CONFIG_FILE_SYSTEMD_RESOLVED}
sed -i "1i ${DHCP_OPTIONS}" ${CONFIG_FILE_SYSTEMD_RESOLVED}
sed -i "1i dhcp-option DNS ${DNS_FORWARDER_IP}" ${CONFIG_FILE_SYSTEMD_RESOLVED}
sed -i "s~\$CLIENTCERTIFICATE~${CLIENT_CERT}~" ${CONFIG_FILE_SYSTEMD_RESOLVED}
sed -i "s~\$PRIVATEKEY~${CLIENT_KEY}~g" ${CONFIG_FILE_SYSTEMD_RESOLVED}

CONFIG=$(cat ./${CONFIG_FILE})
CONFIG_SYSTEMD_RESOLVED=$(cat ./${CONFIG_FILE_SYSTEMD_RESOLVED})

rm -r ./vpnconftemp
rm vpnconfig.zip

jq -n --arg openvpn_config "${CONFIG}" --arg openvpn_config_systemd_resolved "${CONFIG_SYSTEMD_RESOLVED}" '{"openvpn_config":$openvpn_config, "openvpn_config_systemd_resolved":$openvpn_config_systemd_resolved}'
