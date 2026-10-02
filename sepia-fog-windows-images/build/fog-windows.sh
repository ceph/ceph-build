#!/bin/bash
# All the logic for the sepia-fog-windows-images pipeline.  The Jenkinsfile
# calls this script once per stage with a phase argument:
#
#   fog-windows.sh prepare   Clone/bootstrap teuthology
#   fog-windows.sh lock      Lock one testnode per machine type
#   fog-windows.sh deploy    FOG-deploy the existing Windows image and wait
#                            for ssh + the FOG client hostname rename.  With
#                            STARTWITHISO the OS is installed from the
#                            evaluation ISO instead (unattended, via BMC
#                            Redfish virtual media) -- the Windows analog of
#                            the Linux job's STARTWITHMAAS.  With SKIPDEPLOY,
#                            verify the host is already running the right
#                            Windows instead
#   fog-windows.sh update    Run Windows Update via PSWindowsUpdate until no
#                            reboot is pending (bounded)
#   fog-windows.sh prep      DISM component cleanup, drop update/temp litter,
#                            offline-repair the filesystem if NTFS is dirty
#   fog-windows.sh capture   Create FOG capture tasks, reboot, wait
#   fog-windows.sh verify    Deploy the new image on a different host and
#                            check hostname + Windows version
#   fog-windows.sh unlock    Release the testnodes
#   fog-windows.sh cleanup   Best-effort cleanup after a failed/aborted run
#
# The Windows counterpart of sepia-fog-images/build/fog-images.sh: the
# OS-agnostic plumbing is shared via fog-lib.sh, everything in this file is
# Windows policy.  Hosts are reached over ssh as Administrator (Win32
# OpenSSH with PowerShell as the default shell, baked into the golden
# image), so remote commands here are PowerShell, not sh.  There is no
# ansible phase and no MAAS seeding: the golden image is installed by hand
# once (see the README) and refreshed by this job from then on.
#
# Per-host state is persisted in $statefile between phases.  CAPITAL vars
# come from Jenkins.  lowercase are just in this script.

set -ex

source "$(dirname "${BASH_SOURCE[0]}")/../../sepia-fog-images/build/fog-lib.sh"

# host<space>foghostid<space>fogimageid<space>deployed<space>type<space>deployedat
# rows, written by the deploy phase and read by the later ones
statefile="$WORKSPACE/fog-windows-hosts.state"

winver="${WINDOWS_VERSION:-2025}"
winuser="Administrator"

# BMC credentials for Redfish (virtual-media seeding) and IPMI fallback.
# Jenkins provides SEPIA_IPMI_USR/_PSW via credentials(); outside Jenkins
# (a manual seed run on a teuthology host) fall back to the agent's
# /etc/teuthology.yaml, the same single-source-of-truth pattern fog-lib
# uses for the FOG tokens.  set +x so nothing leaks into the console log.
{ set +x; } 2>/dev/null
if [ -z "$SEPIA_IPMI_PASS" ] && [ -r /etc/teuthology.yaml ]; then
  SEPIA_IPMI_PASS=$(awk '$1 == "ipmi_password:" {print $2}' /etc/teuthology.yaml)
fi
ipmiuser=${SEPIA_IPMI_USR:-$(awk '$1 == "ipmi_user:" {print $2}' /etc/teuthology.yaml 2>/dev/null || true)}
ipmiuser=${ipmiuser:-inktank}
set -x

# Where funSeedFromIso caches the evaluation ISO between runs
isocache="$WORKSPACE/windows-${winver}-eval.iso"

# funPauseQueue (fog-lib) reads these.  PAUSEQUEUE defaults to false in the
# job definition: teuthology does not deploy the windows images yet, so
# locking the capture hosts is protection enough.
pausetypes="$MACHINETYPES"

# Should we use teuthology-lock to lock systems?
if [ "$DEFINEDHOSTS" == "" ]; then
  use_teuthologylock=true
else
  use_teuthologylock=false
fi

funAllHosts () {
  if [ "$use_teuthologylock" = true ]; then
    funClaimedHosts | tr "\n" " "
  else
    echo "$DEFINEDHOSTS"
  fi
}

# Run a PowerShell command on a Windows testnode.  Usage: wssh <host> <cmd>
# The explicit user wins over any "User ubuntu" the Linux image job may have
# left in ~/.ssh/config on a shared agent.
wssh () {
  local host=$1
  shift
  ssh $sshopts ${winuser}@${host}.front.sepia.ceph.com "$@"
}

# Clean reboot over ssh, IPMI power cycle as the fallback.  Also the nudge
# callback fog-lib's task waits use when a host never picks its task up --
# on the trial sleds the clean reboot is precisely the path that PXEs
# reliably where a warm IPMI cycle does not.
funReboot () {
  local host=$(echo ${1} | cut -d '.' -f1)
  if wssh $host "shutdown /r /t 0"; then
    return 0
  fi
  funPowerCycle $host
}

# Wait until a freshly-deployed Windows host is reachable over ssh AND has
# taken on its own hostname.  The golden image carries the hostname of
# whatever host it was captured from; the FOG client's HostnameChanger
# renames the host to its FOG host record's name and reboots it, so a
# matching $env:COMPUTERNAME is the Windows equivalent of the Linux
# sentinel file.  Usage: funWaitForWindows <host> [maxretries]
funWaitForWindows () {
  local host=$1 currentretries=0 got
  while true; do
    got=$(wssh $host 'Write-Output $env:COMPUTERNAME' 2>/dev/null | tr -d '\r' | tr '[:upper:]' '[:lower:]') || got=""
    if [ "$got" == "$host" ]; then
      return 0
    fi
    echo "$(date) -- ${host} is not up as itself yet (hostname: '${got:-unreachable}').  Sleeping 30sec"
    sleep 30
    ((++currentretries))
    funRetry $currentretries ${2:-60}
  done
}

# Check that a host is running the Windows Server version this job is
# refreshing.  Usage: funCheckWindowsVersion <host>
funCheckWindowsVersion () {
  local host=$1 product
  product=$(wssh $host '(Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion").ProductName' | tr -d '\r')
  if ! echo "$product" | grep -qi "server ${winver}"; then
    echo "ERROR: $host is running '${product:-unknown}', not Windows Server ${winver}"
    return 1
  fi
  echo "$host is running '$product' as expected"
}

# Thin wrapper around a testnode BMC's Redfish API.
# Usage: funRedfish <host> <METHOD> </redfish/path> [data]
# (xtrace off inside so the BMC credentials stay out of the console log)
funRedfish () {
  { set +x; } 2>/dev/null
  local rc
  curl -sk -X "$2" -u "${ipmiuser}:${SEPIA_IPMI_PASS}" \
    -H "Content-Type: application/json" ${4:+-d "$4"} \
    "https://${1}.ipmi.sepia.ceph.com${3}"
  rc=$?
  set -x
  return $rc
}

# Install Windows from the evaluation ISO, fully unattended -- the Windows
# analog of the Linux job's MAAS seeding.  The ISO is cached in the
# workspace, repacked with a rendered autounattend.xml (hostname, random
# admin password) and a $OEM$ postinstall payload (OpenSSH + lab keys, FOG
# client, PSWindowsUpdate, PXE-first boot order; see postinstall.ps1.in),
# served over HTTP from the agent, and mounted on the testnode's BMC via
# Redfish virtual media with a one-shot UEFI CD boot override.  Setup's
# own reboots land back on the half-installed disk because Windows puts
# its boot entry first; postinstall puts PXE back first and drops
# C:\seed-done, which is what this function waits for.  The admin password
# is written to $WORKSPACE/seed-admin-password-<host> (mode 600) for RDP
# use; ongoing access is ssh keys.  Usage: funSeedFromIso <host>
funSeedFromIso () {
  local host=$1 tmpl=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
  local seeddir=$WORKSPACE/seed-$host frontip port currentretries=0

  if [ -z "$SEPIA_IPMI_PASS" ]; then
    echo "ERROR: no BMC credentials (SEPIA_IPMI_PASS empty and no ipmi_password in /etc/teuthology.yaml); cannot drive virtual media"
    exit 1
  fi

  # Fetch (or reuse) the evaluation ISO
  if [ ! -s "$isocache" ]; then
    echo "Downloading the Windows Server ${winver} evaluation ISO"
    curl -fSL -o "$isocache.part" "$ISOURL"
    mv "$isocache.part" "$isocache"
  fi

  rm -rf $seeddir
  mkdir -p $seeddir

  # Render autounattend.xml and postinstall.ps1 (xtrace off: passwords)
  { set +x; } 2>/dev/null
  local pw pwb64 autob64 keys
  pw=$(openssl rand -hex 12)
  pwb64=$(python3 -c 'import base64,sys; print(base64.b64encode((sys.argv[1]+"AdministratorPassword").encode("utf-16-le")).decode())' "$pw")
  autob64=$(python3 -c 'import base64,sys; print(base64.b64encode((sys.argv[1]+"Password").encode("utf-16-le")).decode())' "$pw")
  (umask 077; echo "$pw" > $WORKSPACE/seed-admin-password-$host)
  sed -e "s|@HOSTNAME@|${host}|" -e "s|@IMAGEINDEX@|${IMAGEINDEX:-2}|" \
      -e "s|@ADMINPASS_B64@|${pwb64}|" -e "s|@AUTOLOGON_B64@|${autob64}|" \
      $tmpl/autounattend.xml.in > $seeddir/autounattend.xml
  set -x
  keys=$(for u in $SSHKEYURLS; do curl -fsSL "$u" || exit 1; done) || {
    echo "ERROR: could not fetch the ssh public keys ($SSHKEYURLS)"
    exit 1
  }
  awk -v r="$keys" '{gsub(/@SSHKEYS@/, r)}1' $tmpl/postinstall.ps1.in \
    | sed -e "s|@FOGSERVER@|${fogserver}|" > $seeddir/postinstall.ps1

  # Repack the ISO with the answer file and the $OEM$ payload.  A Windows
  # ISO cannot be modified in place with xorriso: its big files (notably
  # sources/install.wim) live only in the UDF tree, which xorriso does not
  # read -- a naive -indev/-outdev repack produces a 450KB husk with no
  # boot images (first seed attempt, 2026-10-02).  So: extract with 7z
  # (which does read UDF), split install.wim under the 4GB ISO9660 file
  # limit (Windows Setup picks up install.swm natively), and rebuild with
  # mkisofs semantics.  The EFI boot image must be efisys_noprompt.bin:
  # the stock efisys.bin asks to "Press any key to boot from CD", which
  # would hang an unattended boot forever.
  for tool in 7z wimlib-imagex; do
    command -v $tool >/dev/null || {
      echo "ERROR: $tool is required to repack the Windows ISO (apt install p7zip-full wimtools)"
      exit 1
    }
  done
  local extract=$seeddir/extract etfs efisys wimsize
  7z x -y -o$extract "$isocache" > /dev/null
  cp $seeddir/autounattend.xml $extract/autounattend.xml
  mkdir -p "$extract/sources/\$OEM\$/\$1/seed"
  cp $seeddir/postinstall.ps1 "$extract/sources/\$OEM\$/\$1/seed/postinstall.ps1"
  wimsize=$(stat -c %s $extract/sources/install.wim 2>/dev/null || echo 0)
  if [ "$wimsize" -gt $(( 4000 * 1024 * 1024 )) ]; then
    wimlib-imagex split $extract/sources/install.wim $extract/sources/install.swm 3800
    rm -f $extract/sources/install.wim
  fi
  etfs=$(find $extract -ipath "*boot/etfsboot.com" | head -1)
  efisys=$(find $extract -ipath "*efi/microsoft/boot/efisys_noprompt.bin" | head -1)
  if [ -z "$efisys" ]; then
    echo "ERROR: no efisys_noprompt.bin in the ISO; an unattended CD boot would hang at 'Press any key'"
    exit 1
  fi
  xorriso -as mkisofs -iso-level 3 -J -joliet-long -R \
    -V "WIN_SEED_${winver}" \
    -b "${etfs#$extract/}" -no-emul-boot -boot-load-size 8 \
    -eltorito-alt-boot -e "${efisys#$extract/}" -no-emul-boot \
    -o $seeddir/seed.iso $extract
  rm -rf $extract

  # Serve it to the BMC over HTTP from this agent's front address.  The
  # BMC's CD emulation reads the ISO with Range requests, which stock
  # "python3 -m http.server" does not support (the BMC gives up right
  # after its HEAD probe), so range-http.py it is.
  frontip=$(ip -4 route get $(getent hosts ${host}.ipmi.sepia.ceph.com | awk '{print $1; exit}') | grep -oE 'src [0-9.]+' | awk '{print $2}')
  port=$(( 8600 + RANDOM % 1000 ))
  (cd $seeddir && nohup python3 $tmpl/range-http.py --bind $frontip $port > http.log 2>&1 & echo $! > http.pid)

  # Mount it and boot from it, once.  The virtual-media resource name
  # varies by BMC generation -- CD1 on older Supermicro firmware,
  # VirtualMedia1 on the H13/X14 era, which marks CD1 obsolete (an
  # InsertMedia there is "accepted" but never surfaces Inserted=true) --
  # so discover the CD-capable member instead of hardcoding one, and
  # poll Inserted: the mount is an async BMC task, not instantaneous.
  local vmpath="" member
  for member in $(funRedfish $host GET /redfish/v1/Managers/1/VirtualMedia | jq -r '(.Members // [])[]."@odata.id"'); do
    if funRedfish $host GET "$member" | jq -e '(.MediaTypes // []) | map(ascii_upcase) | any(test("CD|DVD"))' > /dev/null; then
      vmpath=$member
      break
    fi
  done
  if [ -z "$vmpath" ]; then
    echo "ERROR: no CD-capable Redfish virtual media on ${host}'s BMC"
    exit 1
  fi
  funRedfish $host POST "$vmpath/Actions/VirtualMedia.EjectMedia" '{}' || true
  # Both the eject and the insert are async BMC tasks: an insert issued
  # straight after the eject gets a 400 and silently does nothing
  # (observed on trial015), so give the eject a moment, then poll
  # Inserted after the insert.
  sleep 10
  funRedfish $host POST "$vmpath/Actions/VirtualMedia.InsertMedia" \
    '{"Image": "http://'${frontip}':'${port}'/seed.iso", "TransferProtocolType": "HTTP"}'
  currentretries=0
  until funRedfish $host GET "$vmpath" | jq -e '.Inserted == true' > /dev/null; do
    echo "$(date) -- ${host}'s BMC has not mounted the seed ISO yet.  Sleeping 10sec"
    sleep 10
    ((++currentretries))
    # 3min, then give up: check ${seeddir}/http.log and the BMC's
    # virtual media state
    funRetry $currentretries 18
  done
  # The virtual CD is a USB device on Supermicro BMCs: the "Cd" override
  # targets the (empty) SATA bay and the firmware sails past it to the
  # next boot entry, so prefer "UsbCd" wherever the firmware offers it
  # (trial015 booted local CentOS twice under "Cd" before this).
  local boottarget=Cd
  if funRedfish $host GET /redfish/v1/Systems/1 | jq -e '(.Boot["BootSourceOverrideTarget@Redfish.AllowableValues"] // []) | index("UsbCd")' > /dev/null; then
    boottarget=UsbCd
  fi
  funRedfish $host PATCH /redfish/v1/Systems/1 \
    '{"Boot": {"BootSourceOverrideEnabled": "Once", "BootSourceOverrideTarget": "'${boottarget}'", "BootSourceOverrideMode": "UEFI"}}'
  if funRedfish $host GET /redfish/v1/Systems/1 | jq -e '.PowerState == "Off"' > /dev/null; then
    funRedfish $host POST /redfish/v1/Systems/1/Actions/ComputerSystem.Reset '{"ResetType": "On"}'
  else
    funRedfish $host POST /redfish/v1/Systems/1/Actions/ComputerSystem.Reset '{"ResetType": "ForceRestart"}'
  fi

  # A from-scratch install takes a while; C:\seed-done is dropped by
  # postinstall.ps1 at the very end
  until wssh $host 'Test-Path C:\seed-done' 2>/dev/null | tr -d '\r' | grep -q True; do
    echo "$(date) -- Windows setup still running on ${host}.  Sleeping 60sec"
    sleep 60
    ((++currentretries))
    # Retry for 100min
    funRetry $currentretries 100
  done

  # The postinstall log tells us whether the PXE-first reorder worked; a
  # Windows-first boot order would keep every later reboot out of FOG's
  # hands, so this is fatal, not cosmetic.
  wssh $host 'Get-Content C:\seed\postinstall.log -Tail 40' || true
  if ! wssh $host 'Get-Content C:\seed\postinstall.log' | tr -d '\r' | grep -q '^PXE-first: ok'; then
    echo "ERROR: postinstall could not put PXE first in ${host}'s UEFI boot order; fix it by hand (bcdedit /set '{fwbootmgr}' displayorder <pxe-entry> /addfirst) before capturing"
    exit 1
  fi
  wssh $host 'Remove-Item -Recurse -Force C:\seed-done, C:\seed\FOGService.msi -ErrorAction SilentlyContinue; exit 0'

  # Unhook the virtual media and stop the HTTP server
  funRedfish $host POST "$vmpath/Actions/VirtualMedia.EjectMedia" '{}' || true
  funRedfish $host PATCH /redfish/v1/Systems/1 '{"Boot": {"BootSourceOverrideEnabled": "Disabled"}}' || true
  kill $(cat $seeddir/http.pid) 2>/dev/null || true
  rm -f $seeddir/seed.iso
}

phase_prepare () {
  # Clone or update teuthology (teuthology-lock/teuthology-queue).
  # (reset --hard because bootstrap dirties uv.lock in the persistent workspace)
  cd $WORKSPACE
  if [ ! -d teuthology ]; then
    git clone https://github.com/ceph/teuthology
    cd teuthology
    git checkout $TEUTHOLOGYBRANCH
  else
    cd teuthology
    git fetch
    git reset --hard
    git checkout -f main
    git reset --hard origin/main
    git checkout -f $TEUTHOLOGYBRANCH
  fi
  ./bootstrap
  cd $WORKSPACE

  rm -f $statefile
}

phase_lock () {
  funActivateVenv

  # See phase_lock in fog-images.sh: pause before claiming so the dispatcher
  # cannot race us for freed nodes.  No-op with the default PAUSEQUEUE=false.
  funPauseQueue 7200

  if [ "$use_teuthologylock" != true ]; then
    echo "DEFINEDHOSTS set; skipping locking"
    return 0
  fi

  set +e
  for type in $MACHINETYPES; do
    currentretries=0
    while true; do
      numlocked=$(funClaimedHosts $type | wc -l | tr -d '[:space:]')
      [ "$numlocked" -ge 1 ] && break
      claimed=false
      for candidate in $(funFreeHosts $type); do
        if funClaim $candidate; then
          claimed=true
          break
        fi
      done
      if [ "$claimed" != true ]; then
        sleep 5
      fi
      ((++currentretries))
      # Retry for 1hr
      funRetry $currentretries 720
    done
  done
  set -e
}

phase_deploy () {
  funActivateVenv

  fogcaptureid=$(funFogApi GET /tasktype '{"name": "Capture"}' | jq -r '.tasktypes[0].id')
  fogdeployid=$(funFogApi GET /tasktype '{"name": "Deploy"}' | jq -r '.tasktypes[0].id')
  if [ -z "$fogcaptureid" ] || [ "$fogcaptureid" == "null" ] || [ -z "$fogdeployid" ] || [ "$fogdeployid" == "null" ]; then
    echo "ERROR: Could not talk to the FOG API at http://${fogserver}/fog.  Check the endpoint and tokens."
    exit 1
  fi

  rm -f $statefile
  touch $statefile

  for type in $MACHINETYPES; do
    if [ "$use_teuthologylock" = true ]; then
      host=$(funClaimedHosts $type | sort | head -n 1)
    else
      host=$(echo $DEFINEDHOSTS | tr ' ' '\n' | grep "^${type}" | head -n 1 || true)
    fi
    if [ -z "$host" ]; then
      echo "ERROR: no $type host to work with"
      exit 1
    fi
    imagename="${type}_windows_${winver}"

    foghostid=$(funFogApi GET /host '{"name": "'${host}'"}' | jq -r '.hosts[0].id')
    if [ -z "$foghostid" ] || [ "$foghostid" == "null" ]; then
      echo "ERROR: $host is not registered in FOG at http://${fogserver}/fog"
      exit 1
    fi

    # Make sure the image we'll capture into exists.  osID 9 is FOG's
    # "Windows 10" family, which is what current FOG offers for the
    # Win10/Server generation; it only steers FOG client behavior, not the
    # capture itself.  Same create-template-last ordering lesson as the
    # Linux job: find the deployable image BEFORE creating the template.
    deployimageid=""
    if [ "$SKIPDEPLOY" != "true" ]; then
      deployimageid=$(funUsableImageId $imagename)
    fi
    captureimageid=$(funFogApi GET /image '{"name": "'${imagename}'"}' | jq -r '.images[0].id')
    if [ "$captureimageid" == "null" ] || [ -z "$captureimageid" ]; then
      funFogApi POST /image/ '{ "imageTypeID": "1", "imagePartitionTypeID": "1", "name": "'${imagename}'", "path": "'${imagename}'", "osID": "9", "format": "0", "magnet": "", "protected": "0", "compress": "6", "isEnabled": "1", "toReplicate": "1", "os": {"id": "9", "name": "Windows 10", "description": ""}, "imagepartitiontype": {"id": "1", "name": "Everything", "type": "all"}, "imagetype": {"id": "1", "name": "Single Disk - Resizable", "type": "n"}, "imagetypename": "Single Disk - Resizable", "imageparttypename": "Everything", "osname": "Windows 10", "storagegroupname": "default"}' || true
      captureimageid=$(funFogApi GET /image '{"name": "'${imagename}'"}' | jq -r '.images[0].id')
      if [ "$captureimageid" == "null" ] || [ -z "$captureimageid" ]; then
        echo "ERROR: Could not create FOG image template ${imagename}"
        exit 1
      fi
    fi

    deployed=false
    deployedat=""
    if [ "$STARTWITHISO" == "true" ]; then
      # Install the OS from the evaluation ISO instead of deploying an
      # existing image: the seeding path for a brand-new Windows version
      # (or machine type) with no captured image yet
      funSeedFromIso $host
      funCheckWindowsVersion $host || exit 1
      deployed=iso
    elif [ "$SKIPDEPLOY" == "true" ] || [ -z "$deployimageid" ]; then
      if [ "$SKIPDEPLOY" != "true" ]; then
        if [ "$use_teuthologylock" = true ]; then
          echo "ERROR: No captured FOG image named ${imagename} exists so there is nothing to deploy and update."
          echo "Rerun with STARTWITHISO to install Windows from the evaluation ISO, or point DEFINEDHOSTS at a host already running it with SKIPDEPLOY checked."
          exit 1
        fi
        echo "No captured ${imagename} image to deploy; capturing ${host}'s current Windows install"
      else
        echo "SKIPDEPLOY set; capturing ${host}'s current Windows install as ${imagename} without redeploying first"
      fi
      # Seeding path: the host must already be running the target Windows
      funCheckWindowsVersion $host || exit 1
    else
      deployedat=$(funHostDeployedAt $foghostid)
      funFogApi PUT /host/$foghostid '{"imageID": "'${deployimageid}'"}'
      funFogApi POST /host/$foghostid/task '{"taskTypeID": "'${fogdeployid}'"}'
      funReboot $host
      deployed=true
    fi
    echo "$host $foghostid $captureimageid $deployed $type ${deployedat:-none}" >> $statefile
  done

  # Wait for our deploy tasks (fog-lib re-reboots a host whose task is
  # never picked up), then insist FOG recorded a successful deploy
  deployids=$(awk '$4 == "true" {print $2}' $statefile | jq -R . | jq -sc .)
  funWaitForOurTasks "$deployids" 120

  while read -u3 -r host foghostid fogimageid deployed type deployedat; do
    [ "$deployed" == "true" ] || continue
    if [ "$(funHostDeployedAt $foghostid)" == "$deployedat" ]; then
      echo "ERROR: FOG never recorded a successful deploy for $host (deployed timestamp still '${deployedat}'); the deploy task failed or was cancelled.  Not continuing with whatever is on its disk."
      exit 1
    fi
    funWaitForWindows $host 60
    funCheckWindowsVersion $host || exit 1
  done 3< $statefile
}

phase_update () {
  if [ "$UPDATEWINDOWS" != "true" ]; then
    echo "UPDATEWINDOWS=$UPDATEWINDOWS; skipping Windows Update"
    return 0
  fi

  # The Windows Update API refuses most operations from a network logon
  # (which is what an ssh session is), so the standard trick applies: run
  # PSWindowsUpdate (baked into the golden image) from a scheduled task as
  # SYSTEM and watch for its done-marker.  Up to 3 rounds, rebooting
  # between rounds while updates keep asking for one.
  cat > $WORKSPACE/fog-wu.ps1 <<'EOF'
$ErrorActionPreference = 'Continue'
Start-Transcript -Path C:\fog-wu.log -Append
Import-Module PSWindowsUpdate
Install-WindowsUpdate -AcceptAll -IgnoreReboot -Confirm:$false
Stop-Transcript
New-Item -ItemType File -Path C:\fog-wu.done -Force | Out-Null
EOF

  while read -u3 -r host foghostid fogimageid deployed type deployedat; do
    wssh $host 'if (-not (Get-Module -ListAvailable PSWindowsUpdate)) { Write-Error "PSWindowsUpdate is not in the golden image"; exit 1 }'
    scp $sshopts $WORKSPACE/fog-wu.ps1 ${winuser}@${host}.front.sepia.ceph.com:C:/fog-wu.ps1
    for round in 1 2 3; do
      echo "Windows Update round $round on $host"
      wssh $host 'Remove-Item C:\fog-wu.done -ErrorAction SilentlyContinue; schtasks /Create /TN FogWU /TR "powershell -NoProfile -ExecutionPolicy Bypass -File C:\fog-wu.ps1" /SC ONCE /ST 00:00 /RU SYSTEM /F; schtasks /Run /TN FogWU'
      currentretries=0
      until wssh $host 'Test-Path C:\fog-wu.done' 2>/dev/null | tr -d '\r' | grep -q True; do
        echo "$(date) -- Windows Update still running on $host.  Sleeping 60sec"
        sleep 60
        ((++currentretries))
        # Retry for 1hr per round
        funRetry $currentretries 60
      done
      wssh $host 'Get-Content C:\fog-wu.log -Tail 20' || true
      if wssh $host 'Import-Module PSWindowsUpdate; (Get-WURebootStatus -Silent).ToString()' | tr -d '\r' | grep -qi true; then
        echo "$host wants a reboot after update round $round; rebooting"
        funReboot $host
        funWaitForWindows $host 60
      else
        echo "No reboot pending on $host after round $round; updates are done"
        break
      fi
    done
  done 3< $statefile
}

phase_prep () {
  # Shrink and clean the install before capture, then make sure NTFS is
  # clean so FOG's ntfsresize starts from a healthy filesystem (the Windows
  # stand-in for the Linux job's fsck phase).
  while read -u3 -r host foghostid fogimageid deployed type deployedat; do
    wssh $host 'dism /online /Cleanup-Image /StartComponentCleanup /ResetBase' || true
    wssh $host 'Remove-Item -Recurse -Force C:\fog-wu.ps1, C:\fog-wu.log, C:\fog-wu.done -ErrorAction SilentlyContinue; schtasks /Delete /TN FogWU /F 2>$null; Remove-Item -Recurse -Force $env:TEMP\*, C:\Windows\Temp\* -ErrorAction SilentlyContinue; exit 0'
    # Drop the FOG client's pairing token so every clone of this capture
    # enrolls with the server fresh (by MAC); a captured token would make
    # the server reject the clones' check-ins and HostnameChanger would
    # never rename them.
    wssh $host 'Stop-Service FOGService -ErrorAction SilentlyContinue; Remove-Item "C:\Program Files (x86)\FOG\token.dat", "C:\Program Files\FOG\token.dat" -ErrorAction SilentlyContinue; exit 0'
    if wssh $host 'fsutil dirty query C:' | tr -d '\r' | grep -qi " is dirty"; then
      echo "${host}'s C: is dirty; scheduling an offline repair and rebooting"
      wssh $host 'Repair-Volume -DriveLetter C -OfflineScanAndFix' || true
      funReboot $host
      funWaitForWindows $host 60
    fi
  done 3< $statefile
}

phase_capture () {
  funActivateVenv

  fogcaptureid=$(funFogApi GET /tasktype '{"name": "Capture"}' | jq -r '.tasktypes[0].id')

  # Unlike the Linux job there is no deploy-drain here: teuthology does not
  # deploy ${type}_windows_* images, so nothing can be mid-deploy from the
  # image we are about to rewrite.  Re-arm the pause expiry all the same
  # (no-op with the default PAUSEQUEUE=false).
  funPauseQueue 7200

  # From this point on the image is being rewritten; cleanup uses this
  # marker to know it must NOT unpause the queue on failure.
  touch $WORKSPACE/captures-started

  while read -u3 -r host foghostid fogimageid deployed type deployedat; do
    funFogApi PUT /host/$foghostid '{"imageID": "'${fogimageid}'"}'
    funFogApi POST /host/$foghostid/task '{"taskTypeID": "'${fogcaptureid}'"}'
    funReboot $host
  done 3< $statefile

  capturehostids=$(awk '{print $2}' $statefile | jq -R . | jq -sc .)
  funWaitForCaptureTasks "$capturehostids"
}

phase_verify () {
  # Deploy the freshly-captured image onto a different host and make sure
  # it boots, renames itself, and runs the Windows version it claims.
  funActivateVenv

  fogdeployid=$(funFogApi GET /tasktype '{"name": "Deploy"}' | jq -r '.tasktypes[0].id')

  verifyfile="$WORKSPACE/fog-windows-verify.state"
  rm -f $verifyfile
  touch $verifyfile
  extrahosts=""

  while read -u3 -r host foghostid fogimageid deployed type deployedat; do
    if [ "$use_teuthologylock" = true ]; then
      target=$(funClaimExtraHost $type) || {
        echo "ERROR: Could not claim a $type host to verify ${type}_windows_${winver}.  Queue stays paused."
        exit 1
      }
      extrahosts="$extrahosts $target"
    else
      echo "WARNING: DEFINEDHOSTS; verifying ${type}_windows_${winver} on the host it was captured from."
      target=$host
    fi
    targetid=$(funFogApi GET /host '{"name": "'${target}'"}' | jq -r '.hosts[0].id')
    if [ -z "$targetid" ] || [ "$targetid" == "null" ]; then
      echo "ERROR: verify host $target is not registered in FOG.  Queue stays paused."
      exit 1
    fi
    verifydeployedat=$(funHostDeployedAt $targetid)
    funFogApi PUT /host/$targetid '{"imageID": "'${fogimageid}'"}'
    funFogApi POST /host/$targetid/task '{"taskTypeID": "'${fogdeployid}'"}'
    funReboot $target
    echo "$target $targetid ${verifydeployedat:-none}" >> $verifyfile
  done 3< $statefile

  verifyids=$(awk '{print $2}' $verifyfile | jq -R . | jq -sc .)
  funWaitForOurTasks "$verifyids" 120

  while read -u3 -r target targetid verifydeployedat; do
    if [ "$(funHostDeployedAt $targetid)" == "$verifydeployedat" ]; then
      echo "ERROR: FOG never recorded a successful deploy of the new windows_${winver} image on $target.  Queue stays paused."
      exit 1
    fi
    funWaitForWindows $target 60
    funCheckWindowsVersion $target || { echo "ERROR: the new image is not Windows Server ${winver}.  Queue stays paused."; exit 1; }
    echo "Verified: windows_${winver} image boots, renames itself, and runs the right OS on $target"
  done 3< $verifyfile

  funRelease $extrahosts

  funPauseQueue 0
  rm -f $WORKSPACE/captures-started
}

phase_unlock () {
  funActivateVenv

  if [ "$use_teuthologylock" = true ]; then
    funRelease $(funAllHosts)
  fi
}

phase_cleanup () {
  # Best-effort cleanup after a failed or aborted run: delete the job's
  # in-flight FOG tasks, sort the queue out, unlock the testnodes.
  funActivateVenv

  allhosts=$(funAllHosts)
  set +e

  # Unwind a dead STARTWITHISO seed: stop the ISO HTTP server(s) and
  # unhook the virtual media so the node isn't left booting the installer
  for pidfile in $WORKSPACE/seed-*/http.pid; do
    [ -f "$pidfile" ] && kill $(cat $pidfile) 2>/dev/null
  done
  if [ "$STARTWITHISO" == "true" ]; then
    for machine in $allhosts; do
      for member in $(funRedfish $machine GET /redfish/v1/Managers/1/VirtualMedia 2>/dev/null | jq -r '(.Members // [])[]."@odata.id"'); do
        funRedfish $machine POST "$member/Actions/VirtualMedia.EjectMedia" '{}' || true
      done
      funRedfish $machine PATCH /redfish/v1/Systems/1 '{"Boot": {"BootSourceOverrideEnabled": "Disabled"}}' || true
    done
  fi

  for tasktype in Capture Deploy; do
    tasktypeid=$(funFogApi GET /tasktype '{"name": "'${tasktype}'"}' | jq -r '.tasktypes[0].id')
    for task in $(funFogApi GET /task/active '{"typeID": "'${tasktypeid}'"}' | jq -r '(.tasks // [])[].id'); do
      funFogApi DELETE /task/${task}
    done
  done

  if [ "$PAUSEQUEUE" == "true" ]; then
    if [ -f $WORKSPACE/captures-started ]; then
      echo "WARNING: Captures started but the new image(s) were never verified."
      echo "WARNING: LEAVING the teuthology queue paused for: $pausetypes"
      funPauseQueue 7200
    else
      funPauseQueue 0
    fi
  fi

  if [ "$use_teuthologylock" = true ]; then
    funRelease $allhosts
  fi

  return 0
}

case "$1" in
  prepare|lock|deploy|update|prep|capture|verify|unlock|cleanup)
    cd $WORKSPACE
    phase_$1
    ;;
  *)
    echo "Usage: $0 {prepare|lock|deploy|update|prep|capture|verify|unlock|cleanup}"
    exit 1
    ;;
esac
