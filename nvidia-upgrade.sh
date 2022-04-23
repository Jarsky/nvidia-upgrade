#!/bin/bash

OK='\e[0;92m\u2714\e[0m'
ERR='\e[1;31m\u274c\e[0m'

installedVersion=`modinfo /usr/lib/modules/$(uname -r)/updates/dkms/nvidia.ko | grep ^version | awk '{ print $2 }' 2>/dev/null`
latestVersion=`curl -s https://www.nvidia.com/en-us/drivers/unix/ | grep "Latest Production Branch Version:" | grep "Linux x86_64" | sed s/'<\/a>.*'/''/ | awk '{print $NF}' FS='>' | sed 's/ //g'`
BASE_URL=https://us.download.nvidia.com/XFree86/Linux-x86_64

##Upgrade Function
function PerformUpgrade() {
curl -fSsl -O $BASE_URL/$latestVersion/NVIDIA-Linux-x86_64-$latestVersion.run

# Make Executable
chmod +x NVIDIA-Linux-x86_64-$latestVersion.run

# -q Quiet
# -a Accept License
# -n Suppress Questions
# -s Disable ncurses interface
# --dkms Install with DKMS

./NVIDIA-Linux-x86_64-$latestVersion.run -q -a -n -s --dkms

# Delete File afterwards
rm -f NVIDIA-Linux-x86_64-$latestVersion.run
}

##Script Execution
if [[ $EUID -ne 0 ]]; then
   echo ""
   echo -e "[${ERR}]You need to run this as root. e.g sudo $0"
   echo ""
   exit 1
fi

if [ -z $installedVersion ]; then
        echo -e "[$ERR] Installed Version: No Driver detected"
        else
        echo -e "[$OK] Installed Version: $installedVersion"
fi
echo -e "[$OK] New Version: $latestVersion"
echo ""
sleep 2

if [[ $installedVersion = $latestVersion ]]; then
echo -e "[$ERR] Duplicate Detected! Proceed? [Y/n] "
read input
case $input in
      [yY][eE][sS]|[yY])
            echo -e "[$OK] Continuing install"
            sleep 2
            PerformUpgrade;
            ;;
      [nN][oO]|[nN])
            echo -e "[$ERR] Cancelling Install"
            sleep 2
            exit 0
            ;;
      *)
            echo -e "[$ERR] Invalid input..."
            sleep 2
            exit 1
            ;;
esac

else
echo -e "[$OK] All looks OK. Proceeding with Upgrade"
sleep 2
PerformUpgrade;

echo ""
echo -e "[$OK] Install completed"
echo -e "[$OK] Installed Version: $installedVersion"
echo ""
fi
