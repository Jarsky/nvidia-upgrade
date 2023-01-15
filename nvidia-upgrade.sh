#!/bin/bash
#########################################################
#                                                       #
#                 nvidia-upgrade script                 #
#                                                       #
#        Written by Jarsky ||  Updated 12/01/2023       #
#                                                       #
#       v1.5 - Added more checks and docker support     #
#      Install and Upgrade NVIDIA Geforce driver on     #
#                headless Ubuntu Server                 #
#                                                       #
#########################################################

# Config
interactive=true


OK='\e[0;92m\u2714\e[0m'
ERR='\e[1;31m\u274c\e[0m'

# Check if script is being run as root
if [[ $EUID -ne 0 ]]; then
   echo -e "[${ERR}]You need to run this as root. e.g sudo $0"
   exit 1
fi

# Get installed version of NVIDIA driver
installedVersion=$(modinfo /usr/lib/modules/$(uname -r)/updates/dkms/nvidia.ko 2>/dev/null | grep ^version | awk '{ print $2 }')
if [ -z "$installedVersion" ]; then
        installedVersion=$(modinfo /usr/lib/modules/$(uname -r)/kernel/drivers/video/nvidia.ko 2>/dev/null | grep ^version | awk '{ print $2 }')
        if [ -z "$installedVersion" ]; then
        echo -e "[$ERR] Installed Version: No Driver detected"
        installedVersion=""
        else
          echo -e "[$OK] Installed Version: $installedVersion"
        fi
else
  echo -e "[$OK] Installed Version: $installedVersion"
fi

# Get latest version of NVIDIA driver
latestVersion=$(curl -s https://www.nvidia.com/en-us/drivers/unix/ | grep "Latest Production Branch Version:" | grep "Linux x86_64" | sed s/'<\/a>.*'/''/ | awk '{print $NF}' FS='>' | sed 's/ //g')
if [ -z "$latestVersion" ]; then
  echo -e "[$ERR] Failed to retrieve latest version of NVIDIA driver"
  exit 1
else
  echo -e "[$OK] New Version: $latestVersion"
fi

# Check if already latest version
if [[ "$installedVersion" == "$latestVersion" ]] && [ -n "$installedVersion" ]; then
  if [ "$interactive" = "true" ]; then
    echo -e "[$ERR] Duplicate Detected! Proceed? [Y/n] "
    read input
    case $input in
      [yY][eE][sS]|[yY])
        echo -e "[$OK] Continuing install"
        ;;
      [nN][oO]|[nN])
        echo -e "[$ERR] Cancelling Install"
        exit 0
        ;;
      *)
        echo -e "[$ERR] Invalid input..."
        exit 1
        ;;
    esac
  else
    echo -e "[$ERR] Upgrade Skipped. Already latest version."
    exit 0
  fi
fi
#Check if the NVIDIA driver is in use
lsof_output=`lsof /usr/lib/x86_64-linux-gnu/libnvidia-*`
if [ $? -eq 0 ]; then
  # NVIDIA driver is in use, get the PID of the process using it
  pid=`echo "$lsof_output" |  awk -F ' ' '{print $2}' | tail -n 1`
if [[ $pid ]]; then
  # Check if the process is associated with a Docker container
  cgroup_output=`cat /proc/$pid/cgroup`
  if [[ $cgroup_output == *"docker-"* ]]; then
    # Get the container ID from the cgroup output
    container_id=`echo "$cgroup_output" | sed 's/.*docker-\(.*\)\..*/\1/'`
    echo -e "[$ERR] Stopping Docker container $container_id"
    docker stop "$container_id"
  else
    echo -e "[$ERR] Driver is in use by a non-Docker process with PID $pid, exiting"
    exit 1
  fi
 fi
else
  echo -e "[$OK] NVIDIA driver is not in use"

fi

# Perform the NVIDIA driver upgrade

# Download and install latest version of NVIDIA driver
rm -f "NVIDIA-Linux-x86_64-*.run"
 if [ "$interactive" = "true" ]; then
    echo -e "[$OK] Continue with the install? [Y/n] "
    read input
    case $input in
      [yY][eE][sS]|[yY])
        echo -e "[$OK] Continuing install"
        ;;
      [nN][oO]|[nN])
        echo -e "[$ERR] Cancelling Install"
        # Restart the stopped container
        if [[ $cgroup_output == *"docker-"* ]]; then
        echo -e "[$OK] Starting Docker container $container_id"
        docker start "$container_id"
        fi
        exit 0
        ;;
      *)
        echo -e "[$ERR] Invalid input..."
        # Restart the stopped container
        if [[ $cgroup_output == *"docker-"* ]]; then
        echo -e "[$OK] Starting Docker container $container_id"
        docker start "$container_id"
        fi
        exit 1
        ;;
    esac
 fi
BASE_URL=https://us.download.nvidia.com/XFree86/Linux-x86_64
curl -fSsl -O "$BASE_URL/$latestVersion/NVIDIA-Linux-x86_64-$latestVersion.run"
if [ $? -ne 0 ]; then
  echo -e "[$ERR] Failed to download NVIDIA driver"
  exit 1
fi
chmod +x NVIDIA-Linux-x86_64-$latestVersion.run
./NVIDIA-Linux-x86_64-$latestVersion.run -q -a -n -s --dkms

if [ $? -ne 0 ]; then
  echo -e "[$ERR] Failed to install NVIDIA driver"
        # Restart the stopped container
        if [[ $cgroup_output == *"docker-"* ]]; then
        echo -e "[$OK] Starting Docker container $container_id"
        docker start "$container_id"
        fi
        exit 1
fi
        rm -f "NVIDIA-Linux-x86_64-$latestVersion.run"
        echo -e "[$OK] Installation Complete."
        echo -e "[$OK] Installed Version: $latestVersion"

        # Restart the stopped container
        if [[ $cgroup_output == *"docker-"* ]]; then
        echo -e "[$OK] Starting Docker container $container_id"
        docker start "$container_id"
        fi
exit 0
