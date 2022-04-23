# nvidia-upgrade
Install &amp; Upgrade the latest Nvidia DKMS driver for Ubuntu


Overview
-------------

Script to install and upgrade the latest NVIDIA Geforce drivers for Ubuntu. 
This is for headless servers that are using a Geforce Card for example a Plex / Emby server. 

The script is a basic one which will download the latest driver and install it silently. 

By default the script is interactive if it detects the latest is already installed.<br>
To skip this and fully automate the script, change `interactive=true` to `interactive=false`

