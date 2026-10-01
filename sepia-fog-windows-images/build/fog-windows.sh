#!/bin/bash
# All the logic for the sepia-fog-windows-images pipeline.  The Jenkinsfile
# calls this script once per stage with a phase argument:
#
#   fog-windows.sh prepare   Clone/bootstrap teuthology
#   fog-windows.sh lock      Lock one testnode per machine type
#   fog-windows.sh deploy    FOG-deploy the existing Windows image and wait
#                            for ssh + the FOG client hostname rename.  With
#                            SKIPDEPLOY (seeding), verify the host is already
#                            running the right Windows instead
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
    if [ "$SKIPDEPLOY" == "true" ] || [ -z "$deployimageid" ]; then
      if [ "$SKIPDEPLOY" != "true" ]; then
        if [ "$use_teuthologylock" = true ]; then
          echo "ERROR: No captured FOG image named ${imagename} exists so there is nothing to deploy and update."
          echo "Seed the golden image by hand (see the README), then rerun with DEFINEDHOSTS pointing at it and SKIPDEPLOY checked."
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
