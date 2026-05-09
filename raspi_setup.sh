#!/bin/bash
# usage: ./setup.sh <device_number> <ssid>
# EX: ./setup.sh 1 cos1

set -e  # 에러 나면 즉시 중단

DEVICE_NUM=$1
SSID=$2

if [ -z "$DEVICE_NUM" ] || [ -z "$SSID" ]; then
    echo "Usage: $0 <device_number> <ssid>"
    echo "Example: $0 1 cos1"
    exit 1
fi

echo "============================================"
echo "   RasPi Setup Starting - Device #$DEVICE_NUM"
echo "============================================"

# ─────────────────────────────
# 2. 기본 설치 및 vim 설정
# ─────────────────────────────
echo ""
echo "[1/7] >> Installing base packages & configuring vimrc..."
sudo apt-get update
sudo apt-get install -y vim git

git clone https://github.com/hw5773/conf.git
cd conf
cp vimrc ~/.vimrc
sudo cp vimrc /root/.vimrc
cd ~
rm -rf conf
echo "[1/7] >> Done."

# ─────────────────────────────
# 3. SSH 서버 설치 및 실행
# ─────────────────────────────
echo ""
echo "[2/7] >> Installing & starting SSH server..."
sudo apt-get install -y openssh-server
sudo update-rc.d ssh enable
sudo service ssh start

echo "       Verifying SSH on port 22:"
sudo lsof -i:22
echo "[2/7] >> Done."

# ─────────────────────────────
# 4. WiFi 드라이버 설치
# ─────────────────────────────
echo ""
echo "[3/7] >> Upgrading kernel & installing WiFi driver (rtl8188eus)..."

# 커널 v6.1로 업그레이드 (드라이버 호환성 필요)
sudo apt-get update && sudo apt-get upgrade -y
sudo apt-get install -y dkms

git clone https://github.com/gglluukk/rtl8188eus
cd rtl8188eus

# 커널 기본 드라이버 두 개 모두 블랙리스트 처리
# r8188eu: 구버전 내장 드라이버
# rtl8xxxu: 신버전 라즈베리파이 OS에서 자동으로 붙는 드라이버
echo 'blacklist r8188eu'  | sudo tee -a /etc/modprobe.d/realtek.conf
echo 'blacklist rtl8xxxu' | sudo tee -a /etc/modprobe.d/realtek.conf

# 부팅 시 8188eu 자동 로드 등록
echo '8188eu' | sudo tee -a /etc/modules

make -j$(nproc) && sudo make install

# 현재 세션에서 기본 드라이버 언로드 후 새 드라이버 로드
sudo modprobe -r rtl8xxxu 2>/dev/null || true  # 없어도 에러 무시
sudo modprobe 8188eu

echo "       Verifying driver (8188eu):"
lsmod | grep 8188eu || echo "WARNING: 8188eu not found in lsmod. Check build logs."
cd ~
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
git clone https://github.com/hw5773/cos-term-project-settings
cd cos-term-project-settings

# ssid를 인자로 받은 값으로 교체
sed -i "s/^ssid=.*/ssid=$SSID/" hostapd.conf

sudo cp dhcpcd.conf  /etc/dhcpcd.conf
sudo cp dnsmasq.conf /etc/dnsmasq.conf
sudo cp hostapd.conf /etc/hostapd/hostapd.conf

sudo update-rc.d dnsmasq enable
sudo update-rc.d hostapd enable
cd ~
echo "[5/7] >> Done."

# ─────────────────────────────────────────────
# 9. 브리지 세팅 (ip_forward + iptables)
# ─────────────────────────────────────────────
echo ""
echo "[6/7] >> Configuring bridge (IP forwarding + iptables)..."

# /etc/sysctl.conf 가 없는 환경(라즈베리파이 OS 신버전)은
# /etc/sysctl.d/ 에 별도 파일로 관리함
if [ -f /etc/sysctl.conf ]; then
    sudo sed -i 's/^#\s*net\.ipv4\.ip_forward\s*=\s*1/net.ipv4.ip_forward=1/' /etc/sysctl.conf
    sudo sysctl -p
else
    echo 'net.ipv4.ip_forward=1' | sudo tee /etc/sysctl.d/99-ipforward.conf
    sudo sysctl -p /etc/sysctl.d/99-ipforward.conf
fi

cd ~/cos-term-project-settings
sudo ./iptables.sh
cd ~
echo "[6/7] >> Done."

# ─────────────────────────────
# 10. DNS 세팅 (/etc/hosts)
# ─────────────────────────────
echo ""
echo "[7/7] >> Updating /etc/hosts..."
echo "172.24.1.1 cos$DEVICE_NUM" | sudo tee -a /etc/hosts
echo "[7/7] >> Done."

# ─────────────────────────────
# 완료
# ─────────────────────────────
echo ""
echo "============================================"
echo "   All steps completed for Device #$DEVICE_NUM!"
echo "   Reboot is strongly recommended."
echo "============================================"
echo ""
echo "Reboot now? (y/n)"
read REBOOT
if [ "$REBOOT" = "y" ]; then
    sudo reboot
fi