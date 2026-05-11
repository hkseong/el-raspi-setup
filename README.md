# el-raspi-setup
### Install Raspbian OS ###  
https://www.raspberrypi.com/software/  
ID: cos#  
PW: computersystems  

###     AP setting      ###  
cd ~  
sudo nmcli dev wifi connect 'Name of the WiFi" password “Password” ifname wlan0  
git clone https://github.com/hkseong/el-raspi-setup  
cd el-raspi-setup  
./setup # cos#  

reboot  
cd el-raspi-setup  
./verify #  
// verify 결과 보고 fail된거는 알아서 해결.  

### In the other device ###  
ssh cos#@172.24.1.1  
// cos00 접속했다가 같은 디바이스에서 cos11 접속하려면 아래 명령어 입력해야 함.  
ssh-keygen -R 172.24.1.1  
