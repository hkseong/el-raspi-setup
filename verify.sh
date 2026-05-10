#!/bin/bash
# usage: ./verify.sh <device_number>
# EX: ./verify.sh 1
# 재부팅 후 실행해서 전체 세팅 검증

DEVICE_NUM=$1

if [ -z "$DEVICE_NUM" ]; then
    echo "Usage: $0 <device_number>"
    echo "Example: $0 1"
    exit 1
fi

echo "============================================"
echo "   RasPi Verify - Device #$DEVICE_NUM"
echo "============================================"

declare -A CHECK_RESULTS

check() {
    CHECK_RESULTS["$1"]="$2"
}

# ── SSH ──
if sudo lsof -i:22 | grep -q sshd; then
    check "SSH" "ok"
else
    check "SSH" "fail"
fi

# ── WiFi Driver ──
if lsmod | grep -q 8188eu; then
    check "WiFi Driver" "ok"
else
    check "WiFi Driver" "fail"
fi

# ── wlan1 IP ──
if ip addr show wlan1 | grep -q "172.24.1.1"; then
    check "wlan1 IP" "ok"
else
    check "wlan1 IP" "fail"
fi

# ── AP (hostapd) ──
if sudo systemctl is-active --quiet hostapd; then
    check "AP (hostapd)" "ok"
else
    check "AP (hostapd)" "fail"
fi

# ── DHCP (dnsmasq) ──
if sudo systemctl is-active --quiet dnsmasq; then
    check "DHCP (dnsmasq)" "ok"
else
    check "DHCP (dnsmasq)" "fail"
fi

# ── IP Forwarding ──
if [ "$(cat /proc/sys/net/ipv4/ip_forward)" = "1" ]; then
    check "IP Forwarding" "ok"
else
    check "IP Forwarding" "fail"
fi

# ── iptables ──
if sudo iptables -t nat -L POSTROUTING -n -v | grep -q MASQUERADE; then
    check "iptables" "ok"
else
    check "iptables" "fail"
fi

# ── /etc/hosts ──
if grep -q "172.24.1.1 cos$DEVICE_NUM" /etc/hosts; then
    check "/etc/hosts" "ok"
else
    check "/etc/hosts" "fail"
fi

# ── 결과 출력 ──
echo ""
echo "============================================"
echo "   Verify Summary - Device #$DEVICE_NUM"
echo "============================================"
ALL_OK=true
for key in "SSH" "WiFi Driver" "AP (hostapd)" "DHCP (dnsmasq)" "wlan1 IP" "IP Forwarding" "iptables" "/etc/hosts"; do
    result="${CHECK_RESULTS[$key]}"
    if [ "$result" = "ok" ]; then
        echo "  [OK]   $key"
    else
        echo "  [FAIL] $key"
        ALL_OK=false
    fi
done
echo "============================================"

if [ "$ALL_OK" = true ]; then
    echo "  All checks passed! Device #$DEVICE_NUM is ready."
else
    echo "  Some checks failed. Review the items above."
fi
echo "============================================"
