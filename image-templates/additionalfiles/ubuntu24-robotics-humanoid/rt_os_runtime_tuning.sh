#!/bin/bash
#
# Intel Embodied Intelligence SDK
# Copyright (c) Intel Corporation, 2026
# v2026.1
#

configCore()
{
: <<'EOF'
	#Move all IRQs to core 0.
	for i in `cat /proc/interrupts | grep '^ *[0-9]*[0-9]:' | awk {'print $1'} | sed 's/:$//' `;
	do
		# # Timer
		# if [ "$i" = "0" ]; then
		# 	continue
		# fi
		# # cascade
		# if [ "$i" = "2" ]; then
		# 	continue
		# fi
		echo "setting $i to affine for core zero"
        echo 1 > /proc/irq/$i/smp_affinity
	done

	#Move all rcu tasks to core 0.
	for i in `pgrep rcu`; do taskset -pc 0 $i; done

	#Change realtime attribute of all rcu tasks to SCHED_OTHER and priority 0
	for i in `pgrep rcu`; do chrt -v -o -p 0 $i; done

	#Change realtime attribute of all tasks on core 1 to SCHED_OTHER and priority 0
	for i in `pgrep /1`; do chrt -v -o -p 0 $i; done

	#Change realtime attribute of all tasks to SCHED_OTHER and priority 0
	for i in `ps -A -o pid`; do chrt -v -o -p 0 $i; done

	# Disable kernel machine check interrupt
	echo 0 > /sys/devices/system/machinecheck/machinecheck0/check_interval
EOF

	iso_core_string=$(cat /proc/cmdline | grep -o -E "\bisolcpus=[^ ]*")
	cpus="${iso_core_string#*=}"
	result=()

	cpu_list=$(echo "$cpus" | grep -oE '[0-9]+(-[0-9]+)?' | tr '\n' ',')

	IFS=',' read -ra parts <<< "$cpu_list"
	for part in "${parts[@]}"; do
		[[ -z "$part" ]] && continue
		
		if [[ "$part" == *-* ]]; then
			IFS='-' read -ra range <<< "$part"
			start=${range[0]}
			end=${range[1]}
			for ((i=start; i<=end; i++)); do
				 result+=("$i")
			done
		 else
			result+=("$part")
		fi
	done
	echo "${result[@]}"
       
        # disable all cstates except C0
        # Define the range for CPU indices
	for num in "${result[@]}"; do
            echo $num
	  # Determine the maximum state index for the current CPU
          max_state_index=$(ls /sys/devices/system/cpu/cpu$num/cpuidle/ | grep -o 'state[0-9]*' | sed 's/state//' | sort -n | tail -1)

          # Loop over each state index
          for (( j=1; j<=max_state_index; j++ )); do
            # Disable the current state
            echo 1 > /sys/devices/system/cpu/cpu$num/cpuidle/state$j/disable
            echo "Disabled CPU $num state $j"
          done
	done

	# echo disabling timer migration
	echo 0 > /proc/sys/kernel/timer_migration

	swapoff -a
	# disable thermal interrupt event
	wrmsr -a 0x1b2 0x2000000
}


configCatHwp(){

    # CAT Config
	# L3 cache way: 0xfff
	wrmsr 0xc90 0x3f
	wrmsr 0xc91 0xfc0

	# Ecore L2 cache way: 0xffff
	#wrmsr -p10 0xd10 0xff
	#wrmsr -p11 0xd10 0xff
	#wrmsr -p12 0xd10 0xff
	#wrmsr -p13 0xd11 0xff00
    
	# Set RT Core 13 affinity to CLOS 1, other cores still use CLOS 0
	wrmsr -p1 0xc8f 0x100000000
	
	# HWP Config 
    # RT Core 13 
	# Energe_Performance_Preference: Performance
	# Lock CPU freq @ 3.0GHz
	
    wrmsr 0x774 -p 0 0xf000000080003501
    wrmsr 0x774 -p 1 0xf000000000232323
    wrmsr 0x774 -p 2 0xf000000080003501
    wrmsr 0x774 -p 3 0xf000000080003501
    wrmsr 0x774 -p 4 0xf000000080002501
    wrmsr 0x774 -p 5 0xf000000080002501
    wrmsr 0x774 -p 6 0xf000000080002501
    wrmsr 0x774 -p 7 0xf000000080002501
    wrmsr 0x774 -p 8 0xf000000080002501
    wrmsr 0x774 -p 9 0xf000000080002501
    wrmsr 0x774 -p 10 0xf000000080002501
    wrmsr 0x774 -p 11 0xf000000080002501
    wrmsr 0x774 -p 12 0xf000000080002101
    wrmsr 0x774 -p 13 0xf000000080002101
    wrmsr 0x774 -p 14 0xf000000080002101
    wrmsr 0x774 -p 15 0xf000000080002101
}

services_1=(systemd-timesyncd.service ovsdb-server.service serial-getty@ttyS2.service containerd.service docker.service fwupd-refresh.timer)
services_2=(apt-daily.timer apt-daily.service apt-daily-upgrade.timer apt-daily-upgrade.service snapd.socket snapd.service)
#serial-getty@ttyS0.service systemd-journald.service systemd-journal-flush-msft.service systemd-journal-flush.service systemd-journald.socket systemd-journald-dev-log.socket networkd-dispatcher.service packagekit.service fwupd.service

maskService()
{
	snap stop firmware-updater.firmware-notifier firmware-updater.firmware-updater-app firmware-updater
	
	for service in ${services_1[*]}
	do
		systemctl stop $service
		systemctl disable $service
		systemctl mask $service
	done
	for service in ${services_2[*]}
	do
		systemctl stop $service
		systemctl disable $service
		systemctl mask $service
	done
	#No need in debian-isar
	#apt-get remove unattended-upgrades
	systemctl stop '*.timer'
}

disableUpdate()
{
	sed -i 's/APT::Periodic::Update-Package-Lists "1"/APT::Periodic::Update-Package-Lists "0"/' /etc/apt/apt.conf.d/20auto-upgrades
	sed -i 's/APT::Periodic::Unattended-Upgrade "1"/APT::Periodic::Unattended-Upgrade "0"/' /etc/apt/apt.conf.d/20auto-upgrades
	sed -i 's/APT::Periodic::Update-Package-Lists "1"/APT::Periodic::Update-Package-Lists "0"/' /etc/apt/apt.conf.d/10periodic
	sed -i 's/APT::Periodic::Download-Upgradeable-Packages "1"/APT::Periodic::Download-Upgradeable-Packages "0"/' /etc/apt/apt.conf.d/10periodic
	sed -i 's/APT::Periodic::AutocleanInterval "1"/APT::Periodic::AutocleanInterval "0"/' /etc/apt/apt.conf.d/10periodic
	
	sudo grep -q "^Hidden=true" /etc/xdg/autostart/update-notifier.desktop || echo "Hidden=true" | sudo tee -a /etc/xdg/autostart/update-notifier.desktop
}

checkService()
{
	setup_no_error=true
	for service in ${services[*]}
	do
		num=`systemctl status $service | grep "Loaded: masked" | wc -l`
		if [ $num -gt 0 ]; then
			echo "$service has been masked"
		else
			echo "$service has NOT been masked !!. Please check whether required systemd services are disabled!!!"
			setup_no_error=false
			return
		fi
	done

	if [ "$setup_no_error" = "true" ]
	then
		echo "ALL Configurations have been done"
	else
		echo "PLease do further check about the env setup!!!"
	fi
}

#-----------------------------------------------------------------------
# main
#-----------------------------------------------------------------------
if cat /proc/cmdline | grep -q "isolcpus="; then
	
	configCore
	maskService
	disableUpdate
	configCatHwp
	
	systemctl enable gpu-forcewake.service
	systemctl enable gpu-freq-control.service
	
	systemctl start gpu-forcewake.service
	systemctl start gpu-freq-control.service
	
	echo "[EI_SDK]RT OS runtime tuned" | tee /dev/kmsg
else
	systemctl stop gpu-forcewake.service 
	systemctl stop gpu-freq-control.service 

	echo "[EI_SDK]Stop gpu-frocewake.service and gpu-freq-control.service" | tee /dev/kmsg
fi

