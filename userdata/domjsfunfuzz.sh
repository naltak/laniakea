#! /bin/bash -ex
# https://help.ubuntu.com/community/CloudInit
# http://www.knowceantech.com/2014/03/amazon-cloud-bootstrap-with-userdata-cloudinit-github-puppet/
export DEBIAN_FRONTEND=noninteractive  # Bypass ncurses configuration screens

# -----------------------------------------------------------------------------

# Backup ubuntu user folder files as we will then mount the instance store to it
mkdir /ubuntuUser-old/
cp -pRP /home/ubuntu/.bash_logout /ubuntuUser-old/
cp -pRP /home/ubuntu/.bashrc /ubuntuUser-old/
cp -pRP /home/ubuntu/.profile /ubuntuUser-old/
cp -pRP /home/ubuntu/.ssh/authorized_keys /ubuntuUser-old/
rm -rf /home/ubuntu/

# Format and mount all available instance stores.
# Adapted from http://stackoverflow.com/a/10792689
# REOF = Real End Of File because the script already have EOF
# Quoting of REOF comes from: http://stackoverflow.com/a/8994243
cat << 'REOF' > /home/mountInstanceStore.sh
#!/bin/bash

# This script formats and mounts all available Instance Store devices

##### Variables
devices=( )

##### Functions

function add_device
{
    devices=( "${devices[@]}" $1 )
}

function check_device
{
    if [ -e /dev/$1 ]; then
        add_device $1
    fi
}

function check_devices
{
    # If these lines are added/removed, make sure to check the sed line dealing with /etc/fstab too.
    check_device xvdb
    check_device xvdc
    check_device xvdd
    check_device xvde
    check_device xvdf
    check_device xvdg
    check_device xvdh
    check_device xvdi
    check_device xvdj
    check_device xvdk
}

function print_devices
{
    for device in "${devices[@]}"
    do
        echo Found device $device
    done
}

function do_mount
{
    echo Mounting device $1 on $2
fdisk $1 << EOF
n
p
1



w
EOF
# format!
mkfs -t ext4 $1

if [ ! -e $2 ]; then
    mkdir $2
fi

mount $1 $2

echo "$1   $2        ext4    defaults,nobootwait,comment=cloudconfig          0 2" >> /etc/fstab

}

function mount_devices
{
    for (( i = 0 ; i < ${#devices[@]} ; i++ ))
    do
        if [ $i -eq 0 ]; then
            mountTarget=/home/ubuntu
            # One of the devices may have been mounted.
            umount /mnt 2>/dev/null
        else
            mountTarget=/mnt$(($i+1))
        fi
        do_mount /dev/${devices[$i]} $mountTarget
    done
}


##### Main

check_devices
print_devices
mount_devices
REOF

bash /home/mountInstanceStore.sh

# Remove existing lines involving possibly-mounted devices
# r3.large with 1 instance-store does not mount it.
# c3.large with 2 instance-stores only mounts the first one.
sed -i '/\/dev\/xvd[b-k][ \t]*\/mnt[0-9]*[ \t]*auto[ \t]*defaults,nobootwait,comment=cloudconfig[ \t]*0[ \t]*2/d' /etc/fstab

sudo chown ubuntu:ubuntu /home/ubuntu/
mkdir /home/ubuntu/.ssh/
sudo chown ubuntu:ubuntu /home/ubuntu/.ssh/

# Move ubuntu user dir files back to its home directory which is now mounted on the instance store.
cp -pRP /ubuntuUser-old/.bash_logout /home/ubuntu/.bash_logout
cp -pRP /ubuntuUser-old/.bashrc /home/ubuntu/.bashrc
cp -pRP /ubuntuUser-old/.profile /home/ubuntu/.profile
cp -pRP /ubuntuUser-old/authorized_keys /home/ubuntu/.ssh/authorized_keys
rm -rf /ubuntuUser-old

# -----------------------------------------------------------------------------

# Essential Packages
apt-get --yes --quiet update
apt-get --yes --quiet dist-upgrade
apt-get --yes --quiet build-dep firefox
# Retrieved on 2015-02-05 from MDN Linux Prerequisites: http://mzl.la/1CyPyog
apt-get --yes --quiet install zip unzip mercurial g++ make autoconf2.13 yasm ccache m4 flex
apt-get --yes --quiet install cmake curl gdb git openssh-server screen silversearcher-ag vim
apt-get --yes --quiet install libgtk2.0-dev libglib2.0-dev libdbus-1-dev libdbus-glib-1-dev
apt-get --yes --quiet install libasound2-dev libcurl4-openssl-dev libiw-dev libxt-dev libpulse-dev
apt-get --yes --quiet install mesa-common-dev libgstreamer0.10-dev libgstreamer-plugins-base0.10-dev
apt-get --yes --quiet install lib32z1 gcc-multilib g++-multilib  # For compiling 32-bit in 64-bit OS
apt-get --yes --quiet install valgrind libc6-dbg # Needed for Valgrind
apt-get --yes --quiet install mailutils mdadm
apt-get --yes --quiet install xserver-xorg xsel maven openjdk-7-jdk

# -----------------------------------------------------------------------------

su ubuntu

# Add GitHub as a known host
#sudo -u ubuntu ssh-keyscan github.com >> /home/ubuntu/.ssh/known_hosts

# Set up deployment keys for domjsfunfuzz
@import(userdata/keys/github.domjsfunfuzz.sh)@

sudo chown ubuntu:ubuntu /home/ubuntu/.bashrc


# Populate Mercurial settings.
cat << EOF > /home/ubuntu/.hgrc
[ui]
merge = internal:merge
ssh = ssh -C -v

[extensions]
mq =
progress =
purge =
rebase =

[hostfingerprints]
hg.mozilla.org = af:27:b9:34:47:4e:e5:98:01:f6:83:2b:51:c9:aa:d8:df:fb:1a:27
EOF

sudo chown ubuntu:ubuntu /home/ubuntu/.hgrc


@import(userdata/misc-domjsfunfuzz/location.sh)@

# Download mozilla-central's Mercurial bundle.
sudo -u ubuntu wget -P /home/ubuntu https://ftp.mozilla.org/pub/mozilla.org/firefox/bundles/mozilla-central.hg

# Set up m-c in ~/trees/
sudo -u ubuntu mkdir /home/ubuntu/trees/
sudo -u ubuntu hg --cwd /home/ubuntu/trees/ init mozilla-central

cat << EOF > /home/ubuntu/trees/mozilla-central/.hg/hgrc
[paths]

default = https://hg.mozilla.org/mozilla-central

EOF

sudo chown ubuntu:ubuntu /home/ubuntu/trees/mozilla-central/.hg/hgrc

# Update m-c repository.
sudo -u ubuntu hg -R /home/ubuntu/trees/mozilla-central/ unbundle /home/ubuntu/mozilla-central.hg
sudo -u ubuntu hg -R /home/ubuntu/trees/mozilla-central/ up -C default
sudo -u ubuntu hg -R /home/ubuntu/trees/mozilla-central/ pull
sudo -u ubuntu hg -R /home/ubuntu/trees/mozilla-central/ up -C default

cat << EOF > /home/ubuntu/repoUpdateRunBotPy.sh
#! /bin/bash
sudo apt-get --yes --quiet update 2>&1 | tee /home/ubuntu/log-aptGetUpdate.txt
sudo apt-get --yes --quiet upgrade 2>&1 | tee /home/ubuntu/log-aptGetUpgrade.txt
# Work around lack of disk space in EC2 virtual machines until we have something better with shell-cache
rm -rf /home/ubuntu/shell-cache 2>&1 | tee /home/ubuntu/log-rmShellCache.txt
/usr/bin/env python -u /home/ubuntu/fuzzing/util/reposUpdate.py 2>&1 | tee /home/ubuntu/log-reposUpdate.txt
/usr/bin/env python -u /home/ubuntu/fuzzing/bot.py -b "--random" -t "js" --target-time=26000 2>&1 | tee /home/ubuntu/log-botPy.txt
EOF

sudo chown ubuntu:ubuntu /home/ubuntu/repoUpdateRunBotPy.sh

cat << EOF > /etc/cron.d/domjsfunfuzz
SHELL=/bin/bash
#PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/usr/games:/usr/local/games
@import(userdata/misc-domjsfunfuzz/extra.sh)@
#USER=ubuntu
#LOGNAME=ubuntulog
#HOME=/home/ubuntu
3 */8 * * *  ubuntu  /usr/bin/env bash /home/ubuntu/repoUpdateRunBotPy.sh
EOF

sudo chown root:root /etc/cron.d/domjsfunfuzz

##############

# Overwrite CloudInit's configuration setup on (re)boot
cat << EOF > /home/ubuntu/overwriteCloudInitConfig.sh
# Make sure coredumps have the pid appended
echo '1' > /proc/sys/kernel/core_uses_pid

# Edit ~/.bashrc
cat << REOF >> /home/ubuntu/.bashrc

ulimit -c unlimited

# Expand bash shell history length
export HISTTIMEFORMAT="%h %d %H:%M:%S "
HISTSIZE=10000

# Modify bash prompt
export PS1="[\u@\h \d \t \W ] $ "

export LD_LIBRARY_PATH=.

ccache -M 4G
REOF
EOF

cat << EOF > /etc/cron.d/overwriteCloudInitConfigOnBoot
SHELL=/bin/bash
@import(userdata/misc-domjsfunfuzz/extra.sh)@
@reboot root /usr/bin/env bash /home/ubuntu/overwriteCloudInitConfig.sh
EOF

##############

sudo reboot
