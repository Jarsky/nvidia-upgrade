# nvidia-upgrade
Install &amp; Upgrade the latest Nvidia DKMS driver for Ubuntu


Overview
-------------

Script to install and upgrade the latest NVIDIA Geforce drivers for Ubuntu. <br>
This is for headless servers that are using a Geforce Card for example a Plex / Emby server. 

The script is a basic one which will download the latest driver and install it silently. 

By default the script is interactive if it detects the latest is already installed.<br>
To skip this and fully automate the script, change `interactive=true` to `interactive=false`


Usage
------------

- Download the script or clone the repository to your server
- Make the script executable i.e `chmod +x nvidia-upgrade.sh`
- Run the script as root i.e `sudo ./nvidia-upgrade.sh`

#Optionally

- You can set the script to fully auto by changing `interactive=true` to `interactive=false`
- Create a CRON Job to run the script automatically e.g once a month
