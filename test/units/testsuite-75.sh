#!/usr/bin/env bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# vi: ts=4 sw=4 tw=0 et:

set -eux
set -o pipefail

: >/failed

RUN_OUT="$(mktemp)"
NOTIFICATION_SUBSCRIPTION_SCRIPT="/tmp/subscribe.sh"
NOTIFICATION_LOGS="/tmp/notifications.txt"

at_exit() {
    set +e
    cat "$NOTIFICATION_LOGS"
}

trap at_exit EXIT

run() {
    "$@" |& tee "$RUN_OUT"
}

run_retry() {
    local ntries="${1:?}"
    local i

    shift

    for ((i = 0; i < ntries; i++)); do
        "$@" && return 0
        sleep .5
    done

    return 1
}

notification_check_host() {
    local host="${1:?}"
    local address="${2:?}"

    # Attempt to parse the notification JSON returned over varlink and check
    # if it contains the requested record. As this is an async operation, let's
    # retry it a couple of times in case it fails.
    #
    # Example JSON:
    # {
    #   "parameters": {
    #     "addresses": [
    #       {
    #         "ifindex": 2,
    #         "family": 2,
    #         "address": [
    #           10,
    #           0,
    #           0,
    #           121
    #         ],
    #         "type": "A"
    #       }
    #     ],
    #     "name": "untrusted.test"
    #   },
    #   "continues": true
    # }
    #
    # Note: we need to do some post-processing of the $NOTIFICATION_LOGS file,
    #       since the JSON objects are concatenated with \0 instead of a newline
    # shellcheck disable=SC2016
    run_retry 10 jq --slurp \
                    --exit-status \
                    --arg host "$host" \
                    --arg address "$address" \
                    '.[] | select(.parameters.name == $host) | .parameters.addresses[] | select(.address | join(".") == $address) | true' \
                    <(tr '\0' '\n' <"$NOTIFICATION_LOGS")
}

### SETUP ###
# Configure network
hostnamectl hostname ns1.unsigned.test
echo "10.0.0.1 ns1.unsigned.test" >>/etc/hosts

mkdir -p /etc/systemd/network
cat >/etc/systemd/network/dns0.netdev <<EOF
[NetDev]
Name=dns0
Kind=dummy
EOF
cat >/etc/systemd/network/dns0.network <<EOF
[Match]
Name=dns0

[Network]
Address=10.0.0.1/24
DNSSEC=allow-downgrade
DNS=10.0.0.1
EOF

# Script to dump DNS notifications to a txt file
cat >$NOTIFICATION_SUBSCRIPTION_SCRIPT <<EOF
#!/bin/sh
printf '
{
  "method": "io.systemd.Resolve.Monitor.SubscribeDnsResolves",
  "more": true
}\0' | nc -U /run/systemd/resolve/io.systemd.Resolve.Monitor > $NOTIFICATION_LOGS
EOF
chmod a+x $NOTIFICATION_SUBSCRIPTION_SCRIPT

{
    echo "FallbackDNS="
    echo "DNSSEC=allow-downgrade"
    echo "DNSOverTLS=opportunistic"
    echo "Monitor=yes"
} >>/etc/systemd/resolved.conf
ln -svf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
# Override the default NTA list, which turns off DNSSEC validation for (among
# others) the test. domain
mkdir -p "/etc/dnssec-trust-anchors.d/"
echo local >/etc/dnssec-trust-anchors.d/local.negative

# Sign the root zone
keymgr . generate algorithm=ECDSAP256SHA256 ksk=yes zsk=yes
# Create a trust anchor for resolved with our root zone
keymgr . ds | sed 's/ DS/ IN DS/g' >/etc/dnssec-trust-anchors.d/root.positive
# Create a bind-compatible trust anchor (for delv)
# Note: the trust-anchors directive is relatively new, so use the original
#       managed-keys one until it's widespread enough
{
    echo 'managed-keys {'
    keymgr . dnskey | sed -r 's/^\. DNSKEY ([0-9]+ [0-9]+ [0-9]+) (.+)$/. static-key \1 "\2";/g'
    echo '};'
} >/etc/bind.keys
# Create an /etc/bind/bind.keys symlink, which is used by delv on Ubuntu
mkdir -p /etc/bind
ln -svf /etc/bind.keys /etc/bind/bind.keys

# Start the services
systemctl unmask systemd-networkd systemd-resolved
systemctl start systemd-networkd systemd-resolved
# Create knot's runtime dir, since from certain version it's provided only by
# the package and not created by tmpfiles/systemd
if [[ ! -d /run/knot ]]; then
    mkdir -p /run/knot
    chown -R knot:knot /run/knot
fi
systemctl start knot
# Wait a bit for the keys to propagate
sleep 4

networkctl status
resolvectl status
resolvectl log-level debug

# Verify that DNS notifications are enabled (Monitor=yes)
run busctl get-property org.freedesktop.resolve1 /org/freedesktop/resolve1 org.freedesktop.resolve1.Manager Monitor
grep -qF 'b true' "$RUN_OUT"

# Start monitoring DNS notifications
systemd-run $NOTIFICATION_SUBSCRIPTION_SCRIPT

# We need to manually propagate the DS records of onlinesign.test. to the parent
# zone, since they're generated online
knotc zone-begin test.
if knotc zone-get test. onlinesign.test. ds | grep .; then
    # Drop any old DS records, if present (e.g. on test re-run)
    knotc zone-unset test. onlinesign.test. ds
fi
# Propagate the new DS records
while read -ra line; do
    knotc zone-set test. "${line[0]}" 600 "${line[@]:1}"
done < <(keymgr onlinesign.test. ds)
knotc zone-commit test.

knotc reload

### SETUP END ###

: "--- nss-resolve/nss-myhostname tests"
# Sanity check
run getent -s resolve hosts ns1.unsigned.test
grep -qE "^10\.0\.0\.1\s+ns1\.unsigned\.test" "$RUN_OUT"
notification_check_host "ns1.unsigned.test" "10.0.0.1"

# Issue: https://github.com/systemd/systemd/issues/18812
# PR: https://github.com/systemd/systemd/pull/18896
# Follow-up issue: https://github.com/systemd/systemd/issues/23152
# Follow-up PR: https://github.com/systemd/systemd/pull/23161
# With IPv6 enabled
run getent -s resolve hosts localhost
grep -qE "^::1\s+localhost" "$RUN_OUT"
run getent -s myhostname hosts localhost
grep -qE "^::1\s+localhost" "$RUN_OUT"
# With IPv6 disabled
sysctl -w net.ipv6.conf.all.disable_ipv6=1
run getent -s resolve hosts localhost
grep -qE "^127\.0\.0\.1\s+localhost" "$RUN_OUT"
run getent -s myhostname hosts localhost
grep -qE "^127\.0\.0\.1\s+localhost" "$RUN_OUT"
sysctl -w net.ipv6.conf.all.disable_ipv6=0


: "--- Basic resolved tests ---"
# Issue: https://github.com/systemd/systemd/issues/22229
# PR: https://github.com/systemd/systemd/pull/22231
FILTERED_NAMES=(
    "0.in-addr.arpa"
    "255.255.255.255.in-addr.arpa"
    "0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.ip6.arpa"
    "hello.invalid"
)

for name in "${FILTERED_NAMES[@]}"; do
    (! run host "$name")
    grep -qF "NXDOMAIN" "$RUN_OUT"
done

# Follow-up
# Issue: https://github.com/systemd/systemd/issues/22401
# PR: https://github.com/systemd/systemd/pull/22414
run dig +noall +authority +comments SRV .
grep -qF "status: NOERROR" "$RUN_OUT"
grep -qE "IN\s+SOA\s+ns1\.unsigned\.test\." "$RUN_OUT"


: "--- ZONE: unsigned.test. ---"
run dig @10.0.0.1 +short unsigned.test
grep -qF "10.0.0.101" "$RUN_OUT"
run resolvectl query unsigned.test
grep -qF "unsigned.test: 10.0.0.10" "$RUN_OUT"
grep -qF "authenticated: no" "$RUN_OUT"
run dig @10.0.0.1 +short MX unsigned.test
grep -qF "15 mail.unsigned.test." "$RUN_OUT"
run resolvectl query --legend=no -t MX unsigned.test
grep -qF "unsigned.test IN MX 15 mail.unsigned.test" "$RUN_OUT"


: "--- ZONE: signed.test (static DNSSEC) ---"
# Check the trust chain (with and without systemd-resolved in between
# Issue: https://github.com/systemd/systemd/issues/22002
# PR: https://github.com/systemd/systemd/pull/23289
run delv @10.0.0.1 signed.test
grep -qF "; fully validated" "$RUN_OUT"
run delv signed.test
grep -qF "; fully validated" "$RUN_OUT"

run dig +short signed.test
grep -qF "10.0.0.10" "$RUN_OUT"
run resolvectl query signed.test
grep -qF "signed.test: 10.0.0.10" "$RUN_OUT"
grep -qF "authenticated: yes" "$RUN_OUT"
run dig @10.0.0.1 +short MX signed.test
grep -qF "10 mail.signed.test." "$RUN_OUT"
run resolvectl query --legend=no -t MX signed.test
grep -qF "signed.test IN MX 10 mail.signed.test" "$RUN_OUT"
# Check a non-existent domain
run dig +dnssec this.does.not.exist.signed.test
grep -qF "status: NXDOMAIN" "$RUN_OUT"
# Check a wildcard record
run resolvectl query -t TXT this.should.be.authenticated.wild.signed.test
grep -qF 'this.should.be.authenticated.wild.signed.test IN TXT "this is a wildcard"' "$RUN_OUT"
grep -qF "authenticated: yes" "$RUN_OUT"

# DNSSEC validation with multiple records of the same type for the same name
# Issue: https://github.com/systemd/systemd/issues/22002
# PR: https://github.com/systemd/systemd/pull/23289
run delv @10.0.0.1 dupe.signed.test
grep -qF "; fully validated" "$RUN_OUT"
run delv dupe.signed.test
grep -qF "; fully validated" "$RUN_OUT"

# Test resolution of CNAME chains
run resolvectl query -t A cname-chain.signed.test
grep -qF "follow14.final.signed.test IN A 10.0.0.14" "$RUN_OUT"
grep -qF "authenticated: yes" "$RUN_OUT"
notification_check_host "cname-chain.signed.test" "10.0.0.14"
# Non-existing RR + CNAME chain
run dig +dnssec AAAA cname-chain.signed.test
grep -qF "status: NOERROR" "$RUN_OUT"
grep -qE "^follow14\.final\.signed\.test\..+IN\s+NSEC\s+" "$RUN_OUT"


: "--- ZONE: onlinesign.test (dynamic DNSSEC) ---"
# Check the trust chain (with and without systemd-resolved in between
# Issue: https://github.com/systemd/systemd/issues/22002
# PR: https://github.com/systemd/systemd/pull/23289
run delv @10.0.0.1 sub.onlinesign.test
grep -qF "; fully validated" "$RUN_OUT"
run delv sub.onlinesign.test
grep -qF "; fully validated" "$RUN_OUT"

run dig +short sub.onlinesign.test
grep -qF "10.0.0.133" "$RUN_OUT"
run resolvectl query sub.onlinesign.test
grep -qF "sub.onlinesign.test: 10.0.0.133" "$RUN_OUT"
grep -qF "authenticated: yes" "$RUN_OUT"
run dig @10.0.0.1 +short TXT onlinesign.test
grep -qF '"hello from onlinesign"' "$RUN_OUT"
run resolvectl query --legend=no -t TXT onlinesign.test
grep -qF 'onlinesign.test IN TXT "hello from onlinesign"' "$RUN_OUT"
# Check a non-existent domain
# Note: mod-onlinesign utilizes Minimally Covering NSEC Records, hence the
#       different response than with "standard" DNSSEC
run dig +dnssec this.does.not.exist.onlinesign.test
grep -qF "status: NOERROR" "$RUN_OUT"
grep -qF "NSEC \\000.this.does.not.exist.onlinesign.test." "$RUN_OUT"
# Check a wildcard record
run resolvectl query -t TXT this.should.be.authenticated.wild.onlinesign.test
grep -qF 'this.should.be.authenticated.wild.onlinesign.test IN TXT "this is an onlinesign wildcard"' "$RUN_OUT"
grep -qF "authenticated: yes" "$RUN_OUT"

# Resolve via dbus method
run busctl call org.freedesktop.resolve1 /org/freedesktop/resolve1 org.freedesktop.resolve1.Manager ResolveHostname 'isit' 0 secondsub.onlinesign.test 0 0
grep -qF '10 0 0 134 "secondsub.onlinesign.test"' "$RUN_OUT"
notification_check_host "secondsub.onlinesign.test" "10.0.0.134"

: "--- ZONE: untrusted.test (DNSSEC without propagated DS records) ---"
run dig +short untrusted.test
grep -qF "10.0.0.121" "$RUN_OUT"
run resolvectl query untrusted.test
grep -qF "untrusted.test: 10.0.0.121" "$RUN_OUT"
grep -qF "authenticated: no" "$RUN_OUT"

# Issue: https://github.com/systemd/systemd/issues/19472
# 1) Query for a non-existing RR should return NOERROR + NSEC (?), not NXDOMAIN
# FIXME: re-enable once the issue is resolved
#run dig +dnssec AAAA untrusted.test
#grep -qF "status: NOERROR" "$RUN_OUT"
#grep -qE "^untrusted\.test\..+IN\s+NSEC\s+" "$RUN_OUT"
## 2) Query for a non-existing name should return NXDOMAIN, not SERVFAIL
#run dig +dnssec this.does.not.exist.untrusted.test
#grep -qF "status: NXDOMAIN" "$RUN_OUT"

touch /testok
rm /failed
