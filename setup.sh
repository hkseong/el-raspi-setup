#!/bin/bash
# usage: ./setup.sh <device_number> <ssid> [-c]
# EX: ./setup.sh 1 cos1
# EX: ./setup.sh 1 cos1 -c   (stop at each checkpoint)

set -e  # stop on error

DEVICE_NUM=$1
SSID=$2
CONFIRM_MODE=false

# 체크 결과 저장 배열
declare -A CHECK_RESULTS

# -c 옵션 파싱
for arg in "$@"; do
    if [ "$arg" = "-c" ]; then
        CONFIRM_MODE=true
    fi
done

# confirm 함수: -c 옵션 있을 때만 멈춤
confirm() {
    if [ "$CONFIRM_MODE" = true ]; then
        echo ""
        echo "  > $1"
        read -p "  Press [ENTER] to continue..." _
        echo ""
    fi
}

# 자동 체크 함수: 결과를 배열에 저장
check() {
    local name="$1"
    local result="$2"  # "ok", "fail", "reboot"
    CHECK_RESULTS["$name"]="$result"
}

# 최종 결과 출력 함수
print_summary() {
    echo ""
    echo "============================================"
    echo "   Setup Summary - Device #$DEVICE_NUM"
    echo "============================================"
    for key in "SSH" "WiFi Driver" "AP (hostapd)" "DHCP (dnsmasq)" "wlan1 IP" "IP Forwarding" "iptables" "/etc/hosts"; do
        local result="${CHECK_RESULTS[$key]}"
        if [ "$result" = "ok" ]; then
            echo "  [OK]      $key"
        elif [ "$result" = "reboot" ]; then
            echo "  [REBOOT]  $key  <- verify after reboot"
        else
            echo "  [FAIL]    $key"
        fi
    done
    echo "============================================"
    echo "  Run ./verify.sh $DEVICE_NUM after reboot to confirm all items."
    echo "============================================"
}

if [ -z "$DEVICE_NUM" ] || [ -z "$SSID" ]; then
    echo "Usage: $0 <device_number> <ssid> [-c]"
    echo "Example: $0 1 cos1"
    echo "Example: $0 1 cos1 -c   (stop at each checkpoint)"
    exit 1
fi

echo "============================================"
echo "   RasPi Setup Starting - Device #$DEVICE_NUM"
if [ "$CONFIRM_MODE" = true ]; then
    echo "   [Confirm Mode ON]"
fi
echo "============================================"

# ─────────────────────────────
# 2. 기본 설치 및 vim 설정
# ─────────────────────────────
echo ""
echo "[1/7] >> Installing base packages & configuring vimrc..."
cd ~
sudo apt-get update
sudo apt-get install -y vim git

cd ~/el-raspi-setup/conf
cp vimrc ~/.vimrc
sudo cp vimrc /root/.vimrc
cd ~
echo "[1/7] >> Done."

# ─────────────────────────────
# 3. SSH 서버 설치 및 실행
# ─────────────────────────────
echo ""
echo "[2/7] >> Installing & starting SSH server..."
sudo apt-get install -y openssh-server
sudo update-rc.d ssh enable
sudo service ssh start

echo ""
echo "       Verifying SSH on port 22:"
sudo lsof -i:22

if sudo lsof -i:22 | grep -q sshd; then
    check "SSH" "ok"
else
    check "SSH" "fail"
fi
confirm "sshd process should be visible above. If nothing shows, SSH failed to start."
echo "[2/7] >> Done."

# ─────────────────────────────
# 4. WiFi 드라이버 설치
# ─────────────────────────────
# ─────────────────────────────
# 4. WiFi 드라이버 설치
# ─────────────────────────────
echo ""
echo "[3/7] >> Upgrading kernel & installing WiFi driver (rtl8188eus)..."

# 이미 8188eu 드라이버 로드되어 있으면 스킵
if lsmod | grep -q 8188eu; then
    echo "       8188eu already loaded. Skipping driver build."
    check "WiFi Driver" "ok"
else
    sudo apt-get update && sudo apt-get upgrade -y
    sudo apt-get install -y dkms

    rm -rf ~/rtl8188eus
    git clone https://github.com/gglluukk/rtl8188eus ~/rtl8188eus
    cd ~/rtl8188eus

    # 블랙리스트 처리 (set -e 영향 안 받게 grep을 if로 감쌈)
    if ! grep -qF 'blacklist r8188eu' /etc/modprobe.d/realtek.conf 2>/dev/null; then
        echo 'blacklist r8188eu' | sudo tee -a /etc/modprobe.d/realtek.conf
    fi
    if ! grep -qF 'blacklist rtl8xxxu' /etc/modprobe.d/realtek.conf 2>/dev/null; then
        echo 'blacklist rtl8xxxu' | sudo tee -a /etc/modprobe.d/realtek.conf
    fi
    if ! grep -qF '8188eu' /etc/modules 2>/dev/null; then
        echo '8188eu' | sudo tee -a /etc/modules
    fi

    make -j$(nproc) && sudo make install

    sudo modprobe -r rtl8xxxu 2>/dev/null || true
    sudo modprobe 8188eu

    echo ""
    echo "       Verifying driver (8188eu):"
    lsmod | grep 8188eu || echo "WARNING: 8188eu not found in lsmod."

    if lsmod | grep -q 8188eu; then
        check "WiFi Driver" "ok"
    else
        check "WiFi Driver" "fail"
    fi
    cd ~
fi
confirm "8188eu should be loaded. If WARNING showed, driver install failed."
echo "[3/7] >> Done."
# ─────────────────────────────
# 5. AP 세팅 (dnsmasq, hostapd)
# ─────────────────────────────
echo ""
echo "[4/7] >> Installing dnsmasq & hostapd..."
sudo apt-get install -y dnsmasq hostapd
sudo systemctl unmask hostapd
echo "[4/7] >> Done."

echo ""
echo "[5/7] >> Applying AP config files (ssid: $SSID)..."

cd ~/el-raspi-setup/cos-term-project-settings

sed -i "s/^ssid=.*/ssid=$SSID/" hostapd.conf

echo ""
echo "       Verifying SSID in hostapd.conf:"
grep "^ssid=" hostapd.conf
confirm "Result should show 'ssid=$SSID'."

# ─────────────────────────────
# wlan1 고정 IP 설정 (강화 버전)
# ─────────────────────────────
if systemctl list-units --type=service | grep -q dhcpcd; then
    sudo cp dhcpcd.conf /etc/dhcpcd.conf
else
    # 기존 wlan1 커넥션 전부 삭제
    EXISTING=$(nmcli -t -f NAME,DEVICE con show | grep wlan1 | cut -d: -f1 || true)
    if [ -n "$EXISTING" ]; then
        echo "$EXISTING" | while read name; do
            sudo nmcli con delete "$name" 2>/dev/null || true
        done
    fi
    
    # wlan1에 연결된 활성 네트워크 끊기
    sudo nmcli dev disconnect wlan1 2>/dev/null || true
    
    # 새 프로파일 생성 (autoconnect yes로 부팅 시 자동 활성화)
    sudo nmcli con add type ethernet ifname wlan1 con-name "ap-wlan1" \
        ip4 172.24.1.1/24 ipv4.method manual \
        connection.autoconnect yes \
        connection.autoconnect-priority 100
    
    # 즉시 IP도 박아넣기 (현재 세션용)
    sudo ip addr flush dev wlan1 2>/dev/null || true
    sudo ip addr add 172.24.1.1/24 dev wlan1
    sudo ip link set wlan1 up
    
    # nmcli 프로파일 활성화 시도
    sudo nmcli con up "ap-wlan1" 2>/dev/null || true
fi

echo ""
echo "       Verifying wlan1 IP:"
ip addr show wlan1 | grep "inet " || echo "WARNING: 172.24.1.1 not found on wlan1."

if ip addr show wlan1 | grep -q "172.24.1.1"; then
    check "wlan1 IP" "ok"
else
    check "wlan1 IP" "reboot"
fi
confirm "Result should show '172.24.1.1'."

sudo cp dnsmasq.conf /etc/dnsmasq.conf
sudo cp hostapd.conf /etc/hostapd/hostapd.conf

sudo update-rc.d dnsmasq enable
sudo update-rc.d hostapd enable
cd ~

# hostapd / dnsmasq: 재부팅 후 확인
check "AP (hostapd)" "reboot"
check "DHCP (dnsmasq)" "reboot"

echo "[5/7] >> Done."

# ─────────────────────────────────────────────
# 9. 브리지 세팅 (ip_forward + iptables)
# ─────────────────────────────────────────────
echo ""
echo "[6/7] >> Configuring bridge (IP forwarding + iptables)..."

if [ -f /etc/sysctl.conf ]; then
    sudo sed -i 's/^#\s*net\.ipv4\.ip_forward\s*=\s*1/net.ipv4.ip_forward=1/' /etc/sysctl.conf
    sudo sysctl -p
else
    echo 'net.ipv4.ip_forward=1' | sudo tee /etc/sysctl.d/99-ipforward.conf
    sudo sysctl -p /etc/sysctl.d/99-ipforward.conf
fi

echo ""
echo "       Verifying IP forwarding:"
cat /proc/sys/net/ipv4/ip_forward

if [ "$(cat /proc/sys/net/ipv4/ip_forward)" = "1" ]; then
    check "IP Forwarding" "ok"
else
    check "IP Forwarding" "fail"
fi
confirm "Result should be '1'."

# ─────────────────────────────
# iptables 설정 (강화 버전)
# ─────────────────────────────
cd ~/el-raspi-setup/cos-term-project-settings
export DEBIAN_FRONTEND=noninteractive

# iptables-persistent 강제 설치
sudo apt-get install -y iptables-persistent

# 직접 iptables 룰 추가 (iptables.sh 의존하지 않음)
sudo iptables -t nat -A POSTROUTING -o wlan0 -j MASQUERADE
sudo iptables -A FORWARD -i wlan0 -o wlan1 -m state --state RELATED,ESTABLISHED -j ACCEPT
sudo iptables -A FORWARD -i wlan1 -o wlan0 -j ACCEPT

# 강제로 저장 (재부팅 후에도 유지)
sudo mkdir -p /etc/iptables
sudo iptables-save | sudo tee /etc/iptables/rules.v4 > /dev/null

# netfilter-persistent 활성화 (재부팅 시 자동 로드)
sudo systemctl enable netfilter-persistent 2>/dev/null || true

echo ""
echo "       Verifying iptables rules:"
sudo iptables -t nat -L POSTROUTING -n -v

echo ""
echo "       Verifying iptables persistence (rules.v4):"
sudo cat /etc/iptables/rules.v4 | grep -E "MASQUERADE|FORWARD" || echo "WARNING: rules.v4 empty."

if sudo iptables -t nat -L POSTROUTING -n -v | grep -q MASQUERADE && \
   sudo cat /etc/iptables/rules.v4 2>/dev/null | grep -q MASQUERADE; then
    check "iptables" "ok"
else
    check "iptables" "fail"
fi
confirm "MASQUERADE rule should be visible above (both runtime and rules.v4)."
cd ~
echo "[6/7] >> Done."

# ─────────────────────────────
# 10. DNS 세팅 (/etc/hosts) - 강화 버전
# ─────────────────────────────
echo ""
echo "[7/7] >> Updating /etc/hosts..."

HOSTS_LINE="172.24.1.1 cos$DEVICE_NUM"
if grep -qF "$HOSTS_LINE" /etc/hosts; then
    echo "       Already exists in /etc/hosts."
else
    echo "$HOSTS_LINE" | sudo tee -a /etc/hosts > /dev/null
    echo "       Added '$HOSTS_LINE' to /etc/hosts."
fi

echo ""
echo "       Verifying /etc/hosts:"
grep "172.24.1.1" /etc/hosts || echo "WARNING: 172.24.1.1 not found in /etc/hosts."

if grep -qF "$HOSTS_LINE" /etc/hosts; then
    check "/etc/hosts" "ok"
else
    check "/etc/hosts" "fail"
fi
confirm "Result should show '$HOSTS_LINE'."
echo "[7/7] >> Done."

# ─────────────────────────────
# 완료 + 최종 요약
# ─────────────────────────────
print_summary

echo ""
echo "Reboot now? (y/n)"
read REBOOT
if [ "$REBOOT" = "y" ]; then
    sudo reboot
fi
