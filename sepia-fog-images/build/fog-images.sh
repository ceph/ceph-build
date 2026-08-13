#!/bin/bash
# All the logic for the sepia-fog-images pipeline.  The Jenkinsfile calls
# this script once per stage with a phase argument:
#
#   fog-images.sh prepare   Clone/bootstrap teuthology and ceph-cm-ansible
#   fog-images.sh lock      Lock testnodes (skipped when DEFINEDHOSTS is set)
#   fog-images.sh deploy    FOG-deploy the existing image for each distro and
#                           wait for the network sentinel file
#   fog-images.sh ansible   Run cephlab.yml and prep-fog-capture.yml
#   fog-images.sh fsck      fsck the root fs (fog-postinit or maas-rescue)
#   fog-images.sh capture   Create FOG capture tasks, reboot, wait
#   fog-images.sh unlock    Release the testnodes
#   fog-images.sh cleanup   Best-effort cleanup after a failed/aborted run
#
# Per-host state (distro and FOG IDs) is persisted in $statefile between
# phases.  CAPITAL vars come from Jenkins.  lowercase are just in this script.

set -ex

# Lab topology.  Adjust here if services move.
fogserver="soko03.front.sepia.ceph.com"
dnsmasqserver="soko01.front.sepia.ceph.com"
dnsmasqconf="/etc/dnsmasq.d/pok/front.conf"
maasurl="http://soko02.front.sepia.ceph.com:5240/MAAS/"
maasprofile="jenkins"

# Testnode host keys change constantly (reimages, rescue environments)
sshopts="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10"

# host<space>distro<space>foghostid<space>fogimageid<space>deployed rows,
# written by the deploy phase and read by the later ones
statefile="$WORKSPACE/fog-hosts.state"

lockdesc="Locked to capture FOG image for Jenkins build $BUILD_NUMBER"

# Map the pipeline credentials() variables onto the names this script uses
{ set +x; } 2>/dev/null
SEPIA_IPMI_PASS=${SEPIA_IPMI_PASS:-$SEPIA_IPMI_PSW}
FOG_USER_TOKEN=${FOG_USER_TOKEN:-$FOG_USR}
FOG_API_TOKEN=${FOG_API_TOKEN:-$FOG_PSW}
set -x

# Read a key from the fog: block of /etc/teuthology.yaml
funTeuthYamlFog () {
  awk -v key="$1" '
    /^fog:/ {inblock=1; next}
    inblock && /^[^ \t]/ {inblock=0}
    inblock && $1 == key":" {print $2; exit}
  ' /etc/teuthology.yaml
}

# Prefer the FOG endpoint and tokens from the agent's /etc/teuthology.yaml so
# there's a single source of truth and Jenkins credentials can't go stale.
# The Jenkins-bound fog credential is the fallback.
# set +x so the tokens don't leak into the (public) console log.
{ set +x; } 2>/dev/null
if [ -r /etc/teuthology.yaml ] && [ -n "$(funTeuthYamlFog endpoint)" ]; then
  fogserver=$(funTeuthYamlFog endpoint | sed -E 's#https?://##; s#/fog/?$##')
  FOG_API_TOKEN=$(funTeuthYamlFog api_token)
  FOG_USER_TOKEN=$(funTeuthYamlFog user_token)
  echo "Using FOG endpoint http://${fogserver}/fog from /etc/teuthology.yaml"
fi
set -x

# The sentinel file cephlab_rc_local creates once first-boot network/hostname
# configuration is done
sentinelfile=$(funTeuthYamlFog sentinel_file)
: "${sentinelfile:=/.cephlab_hostname_set}"

# Thin wrapper around the FOG API.  Usage: funFogApi <METHOD> </path> [data]
# (xtrace is suppressed inside so the API tokens stay out of the console log)
funFogApi () {
  { set +x; } 2>/dev/null
  local rc
  curl -f -s -k \
    -H "fog-api-token: ${FOG_API_TOKEN}" \
    -H "fog-user-token: ${FOG_USER_TOKEN}" \
    -X "$1" "http://${fogserver}/fog${2}" ${3:+-d "$3"}
  rc=$?
  set -x
  return $rc
}

# Converts distro friendly names into FOG image names
funSetProfiles () {
  splitdistro=$(echo $1 | cut -d '_' -f1)
  distroversion=$(echo $1 | cut -d '_' -f2)
  case "$splitdistro" in
    ubuntu|rhel|centos|rocky|alma|opensuse)
      fogprofile="${splitdistro}_${distroversion}"
      ;;
    *)
      echo "Unknown profile $1"
      exit 1
      ;;
  esac
}

funPowerCycle () {
  host=$(echo ${1} | cut -d '.' -f1)
  powerstatus=$(ipmitool -I lanplus -U inktank -P $SEPIA_IPMI_PASS -H ${host}.ipmi.sepia.ceph.com chassis power status | cut -d ' ' -f4-)
  if [ "$powerstatus" == "off" ]; then
     ipmitool -I lanplus -U inktank -P $SEPIA_IPMI_PASS -H ${host}.ipmi.sepia.ceph.com chassis power on
  else
     ipmitool -I lanplus -U inktank -P $SEPIA_IPMI_PASS -H ${host}.ipmi.sepia.ceph.com chassis power cycle
  fi
}

# Reboot a host.  Prefer a clean reboot over ssh (works regardless of
# per-host BMC credentials); fall back to IPMI if the host is unreachable.
funReboot () {
  host=$(echo ${1} | cut -d '.' -f1)
  if ssh $sshopts ubuntu@${host}.front.sepia.ceph.com "sudo shutdown -r +0" ; then
    return 0
  fi
  funPowerCycle $host
}

# There's a few loops that could hang indefinitely if a curl command fails.
# This function takes two arguments: Current and Max number of retries.
# It will fail the job if Current > Max retries.
funRetry () {
  if [ $1 -gt $2 ]; then
    echo "Maximum retries exceeded.  Failing job."
    exit 1
  fi
}

# Repoint a testnode's PXE boot in dnsmasq.  Usage: funSetPxe <host> <maas|fog>
# The first tag on the host's dhcp-host line selects the PXE boot target.
funSetPxe () {
  ssh $sshopts ubuntu@${dnsmasqserver} "sudo sed -i -E 's/^dhcp-host=set:(fog|maas),(.*[,=]${1}\.front\.sepia\.ceph\.com)\$/dhcp-host=set:${2},\2/' $dnsmasqconf && sudo systemctl restart dnsmasq"
}

# Installs a FOG postinit hook that fscks the target disk inside the FOS
# environment before every Capture task.  Idempotent.  Best-effort: if the
# jenkins-build user can't ssh to the FOG server, warn and keep going (the
# hook was installed manually and this just keeps it up to date).
funInstallFogPostinit () {
  if ! ssh $sshopts ubuntu@${fogserver} "sudo mkdir -p /images/dev/postinitscripts && sudo tee /images/dev/postinitscripts/fsck_before_capture.sh > /dev/null" <<'POSTINIT'
#!/bin/bash
# Installed by the sepia-fog-images Jenkins job (ceph-build.git).
# Sourced by fog.postinit inside the FOG (FOS) boot environment.
# Before a Capture task, force-fsck the target disk's filesystems so
# partclone/resize2fs start from a clean filesystem.
if [[ "$type" == "up" ]]; then
  for part in $(blkid -o device | grep "^${hd}"); do
    fstype=$(blkid -o value -s TYPE "$part")
    case "$fstype" in
      ext2|ext3|ext4)
        e2fsck -fp "$part" || e2fsck -fy "$part" || true
        ;;
      xfs)
        xfs_repair "$part" || true
        ;;
    esac
  done
fi
POSTINIT
  then
    echo "WARNING: Could not ssh to ${fogserver} to refresh the fsck postinit hook."
    echo "WARNING: Assuming /images/dev/postinitscripts/fsck_before_capture.sh is already installed there."
    return 0
  fi
  ssh $sshopts ubuntu@${fogserver} "sudo chmod 755 /images/dev/postinitscripts/fsck_before_capture.sh && \
    sudo touch /images/dev/postinitscripts/fog.postinit && \
    ( sudo grep -q fsck_before_capture /images/dev/postinitscripts/fog.postinit || \
      echo '. \${postinitpath}fsck_before_capture.sh' | sudo tee -a /images/dev/postinitscripts/fog.postinit > /dev/null )"
}

funActivateVenv () {
  cd $WORKSPACE
  source $WORKSPACE/teuthology/virtualenv/bin/activate 2>/dev/null || \
    source $WORKSPACE/teuthology/.venv/bin/activate
}

# Should we use teuthology-lock to lock systems?
if [ "$DEFINEDHOSTS" == "" ]; then
  use_teuthologylock=true
else
  use_teuthologylock=false
fi

numdistros=$(echo $DISTROS | wc -w)

funAllHosts () {
  if [ "$use_teuthologylock" = true ]; then
    teuthology-lock --brief -a --status down | grep "$lockdesc" | cut -d '.' -f1 | tr "\n" " "
  else
    echo "$DEFINEDHOSTS"
  fi
}


phase_prepare () {
  # Make sure ssh connections to testnodes/infra hosts default to the ubuntu user
  if ! grep -s 'User.*ubuntu' ~/.ssh/config >/dev/null 2>&1  ; then
    echo "Adding 'User ubuntu' for sepia hosts to ~/.ssh/config"
    mkdir -p ~/.ssh
    cat >> ~/.ssh/config <<EOF
Host *.front.sepia.ceph.com
    User ubuntu
EOF
    chmod 600 ~/.ssh/config
  fi

  # Clone or update teuthology
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

  # Bootstrap teuthology (also needed for teuthology-queue when DEFINEDHOSTS
  # is set, so it's unconditional)
  ./bootstrap
  cd $WORKSPACE

  # Clone or update ceph-cm-ansible
  if [ ! -d ceph-cm-ansible ]; then
    git clone https://github.com/ceph/ceph-cm-ansible
    cd ceph-cm-ansible
    git checkout $CMANSIBLEBRANCH
  else
    cd ceph-cm-ansible
    git fetch
    git reset --hard
    git checkout -f main
    git reset --hard origin/main
    git checkout -f $CMANSIBLEBRANCH
  fi

  rm -f $statefile
}

phase_lock () {
  if [ "$use_teuthologylock" != true ]; then
    echo "DEFINEDHOSTS set; skipping locking"
    return 0
  fi

  funActivateVenv

  # Don't bail if we fail to lock machines
  set +e

  # Keep trying to lock machines
  for type in $MACHINETYPES; do
    numlocked=$(teuthology-lock --brief -a --machine-type $type --status down | grep "$lockdesc" | wc -l)
    currentretries=0
    while [ $numlocked -lt $numdistros ]; do
      # We have to mark the system down and set its desc instead of locking because locking attempts to reimage using FOG.
      teuthology-lock --update --status down --desc "$lockdesc" $(teuthology-lock --brief -a --machine-type $type --status up --locked false | head -n 1 | awk '{ print $1 }')
      # Sleep for a bit so we don't hammer the lock server
      if [ $? -ne 0 ]; then
        sleep 5
      fi
      numlocked=$(teuthology-lock --brief -a --machine-type $type --status down | grep "$lockdesc" | wc -l)
      ((++currentretries))
      # Retry for 1hr
      funRetry $currentretries 720
    done
  done

  set -e
}

phase_deploy () {
  funActivateVenv

  # Get FOG task type IDs
  fogcaptureid=$(funFogApi GET /tasktype '{"name": "Capture"}' | jq -r '.tasktypes[0].id')
  fogdeployid=$(funFogApi GET /tasktype '{"name": "Deploy"}' | jq -r '.tasktypes[0].id')

  # An empty ID means the FOG API is unreachable or the tokens are wrong.
  # (curl failures vanish into the jq pipe, so check explicitly.)
  if [ -z "$fogcaptureid" ] || [ "$fogcaptureid" == "null" ] || [ -z "$fogdeployid" ] || [ "$fogdeployid" == "null" ]; then
    echo "ERROR: Could not talk to the FOG API at http://${fogserver}/fog.  Check the endpoint and tokens."
    exit 1
  fi

  rm -f $statefile
  touch $statefile

  # Pair each locked host with a distro and FOG-deploy the current image for
  # that distro so we have something to update and recapture
  for type in $MACHINETYPES; do
    if [ "$use_teuthologylock" = true ]; then
      lockedhosts=$(teuthology-lock --brief -a --machine-type $type --status down | grep "$lockdesc" | cut -d '.' -f1 | sort)
    else
      lockedhosts=$(echo $DEFINEDHOSTS | grep -o "\w*${type}\w*")
    fi
    # Create arrays using our lists so we can iterate through them
    array1=($lockedhosts)
    array2=($DISTROS)
    for i in $(seq 1 $numdistros); do
      host=${array1[$i-1]}
      funSetProfiles ${array2[$i-1]}
      # Get FOG host ID
      foghostid=$(funFogApi GET /host '{"name": "'${host}'"}' | jq -r '.hosts[0].id')
      if [ -z "$foghostid" ] || [ "$foghostid" == "null" ]; then
        echo "ERROR: $host is not registered in FOG at http://${fogserver}/fog"
        exit 1
      fi
      # Get FOG image ID
      fogimageid=$(funFogApi GET /image '{"name": "'${type}_${fogprofile}'"}' | jq -r '.images[0].id')
      deployed=false
      if [ "$fogimageid" == "null" ] || [ -z "$fogimageid" ]; then
        if [ "$use_teuthologylock" = true ]; then
          # Nothing to deploy.  Brand new distros have to be seeded manually:
          # image a host by hand, then rerun this job with DEFINEDHOSTS
          # pointing at it.
          echo "ERROR: No FOG image named ${type}_${fogprofile} exists so there is nothing to deploy and update."
          echo "Seed the first ${type}_${fogprofile} image manually, then rerun this job with DEFINEDHOSTS set."
          exit 1
        fi
        # DEFINEDHOSTS path: the host is assumed to already be running the
        # target OS.  Create the image template so it can be captured.
        funFogApi POST /image/ '{ "imageTypeID": "1", "imagePartitionTypeID": "1", "name": "'${type}_${fogprofile}'", "path": "'${type}_${fogprofile}'", "osID": "50", "format": "0", "magnet": "", "protected": "0", "compress": "6", "isEnabled": "1", "toReplicate": "1", "os": {"id": "50", "name": "Linux", "description": ""}, "imagepartitiontype": {"id": "1", "name": "Everything", "type": "all"}, "imagetype": {"id": "1", "name": "Single Disk - Resizable", "type": "n"}, "imagetypename": "Single Disk - Resizable", "imageparttypename": "Everything", "osname": "Linux", "storagegroupname": "default"}' || true
        fogimageid=$(funFogApi GET /image '{"name": "'${type}_${fogprofile}'"}' | jq -r '.images[0].id')
      else
        # Associate the image with the host and deploy it
        funFogApi PUT /host/$foghostid '{"imageID": "'${fogimageid}'"}'
        funFogApi POST /host/$foghostid/task '{"taskTypeID": "'${fogdeployid}'"}'
        funReboot $host
        deployed=true
      fi
      echo "$host ${array2[$i-1]} $foghostid $fogimageid $deployed" >> $statefile
    done
  done

  # Wait for the deploy tasks to finish
  currentretries=0
  while read -u3 -r host distro foghostid fogimageid deployed; do
    [ "$deployed" == "true" ] || continue
    while true; do
      activetasks=$(funFogApi GET /task/active | jq -r --arg id "$foghostid" '[(.tasks // [])[] | select((.hostID|tostring) == $id)] | length')
      if [ "$activetasks" == "0" ]; then
        break
      fi
      echo "$(date) -- $host still has an active FOG task.  Sleeping 30sec"
      sleep 30
      ((++currentretries))
      # Retry for 1hr (shared across hosts; deploys run in parallel)
      funRetry $currentretries 120
    done
  done 3< $statefile

  # Wait for the freshly-deployed hosts to come back up and finish their
  # first-boot network/hostname configuration (the sentinel file)
  while read -u3 -r host distro foghostid fogimageid deployed; do
    [ "$deployed" == "true" ] || continue
    currentretries=0
    until ssh $sshopts ubuntu@${host}.front.sepia.ceph.com "stat $sentinelfile > /dev/null 2>&1"; do
      echo "$(date) -- $host has not created $sentinelfile yet.  Sleeping 30sec"
      sleep 30
      ((++currentretries))
      # Retry for 30min
      funRetry $currentretries 60
    done
  done 3< $statefile
}

phase_ansible () {
  funActivateVenv

  # Bring each testnode fully up to date, then prep it for capture
  # set ANSIBLE_CONFIG to allow teuthology to specify collections dir
  while read -u3 -r host distro foghostid fogimageid deployed; do
    ANSIBLE_CONFIG=$WORKSPACE/teuthology/ansible.cfg ansible-playbook $WORKSPACE/ceph-cm-ansible/cephlab.yml -e ansible_ssh_user=ubuntu --limit="${host}*"
    ANSIBLE_CONFIG=$WORKSPACE/teuthology/ansible.cfg ansible-playbook $WORKSPACE/ceph-cm-ansible/tools/prep-fog-capture.yml -e ansible_ssh_user=ubuntu --limit="${host}*"
  done 3< $statefile
}

phase_fsck () {
  # fsck the root filesystems so FOG's partclone/resize2fs are working with
  # clean filesystems when the capture runs
  if [ "$FSCKMETHOD" == "fog-postinit" ]; then
    funInstallFogPostinit
    return 0
  elif [ "$FSCKMETHOD" != "maas-rescue" ]; then
    echo "FSCKMETHOD=$FSCKMETHOD; skipping fsck"
    return 0
  fi

  if ! command -v maas >/dev/null 2>&1; then
    echo "ERROR: FSCKMETHOD=maas-rescue requires the maas CLI on this node (apt install maas-cli)"
    exit 1
  fi
  { set +x; } 2>/dev/null
  maas login $maasprofile $maasurl "$MAAS_API_KEY"
  set -x
  while read -u3 -r host distro foghostid fogimageid deployed; do
    # Point the host's PXE entry at MAAS so rescue mode can boot
    funSetPxe $host maas
    systemid=$(maas $maasprofile machines read hostname=$host | jq -r '.[0].system_id')
    if [ "$systemid" == "null" ] || [ -z "$systemid" ]; then
      echo "ERROR: $host is not enrolled in MAAS; cannot use maas-rescue"
      exit 1
    fi
    maas $maasprofile machine rescue-mode $systemid
    # Wait for the host to enter rescue mode
    currentretries=0
    until [ "$(maas $maasprofile machine read $systemid | jq -r '.status_name')" == "Rescue mode" ]; do
      echo "$(date) -- $host has not entered rescue mode yet.  Sleeping 20sec"
      sleep 20
      ((++currentretries))
      # Retry for 15min
      funRetry $currentretries 45
    done
    # Give sshd in the ephemeral environment a moment
    currentretries=0
    until ssh $sshopts ubuntu@${host}.front.sepia.ceph.com true; do
      sleep 20
      ((++currentretries))
      funRetry $currentretries 30
    done
    # fsck the root (largest ext4) partition; fall back to xfs_repair
    rootpart=$(ssh $sshopts ubuntu@${host}.front.sepia.ceph.com "lsblk -pbnro NAME,FSTYPE,SIZE | awk '\$2==\"ext4\" {print \$3, \$1}' | sort -rn | head -1 | cut -d' ' -f2")
    set +e
    if [ -n "$rootpart" ]; then
      ssh $sshopts ubuntu@${host}.front.sepia.ceph.com "sudo e2fsck -fy $rootpart"
      fsckrc=$?
      # e2fsck exits 1/2 when it fixed errors; that's still success
      if [ $fsckrc -gt 2 ]; then
        echo "ERROR: e2fsck on $host:$rootpart failed with exit code $fsckrc"
        exit 1
      fi
    else
      rootpart=$(ssh $sshopts ubuntu@${host}.front.sepia.ceph.com "lsblk -pbnro NAME,FSTYPE,SIZE | awk '\$2==\"xfs\" {print \$3, \$1}' | sort -rn | head -1 | cut -d' ' -f2")
      if [ -z "$rootpart" ]; then
        echo "ERROR: Could not find an ext4 or xfs root partition on $host"
        exit 1
      fi
      ssh $sshopts ubuntu@${host}.front.sepia.ceph.com "sudo xfs_repair $rootpart" || exit 1
    fi
    set -e
    # Point the host's PXE entry back at FOG for the capture boot
    funSetPxe $host fog
  done 3< $statefile
}

phase_capture () {
  funActivateVenv

  fogcaptureid=$(funFogApi GET /tasktype '{"name": "Capture"}' | jq -r '.tasktypes[0].id')
  fogdeployid=$(funFogApi GET /tasktype '{"name": "Deploy"}' | jq -r '.tasktypes[0].id')

  # Only pause the queue if needed
  pausedqueue=false
  if [ "$PAUSEQUEUE" == "true" ]; then
    # Check for scheduled deploy tasks.  Capturing a new OS image can
    # interrupt active OS deployments.
    deploytasks=$(funFogApi GET /task/active '{"typeID": "'${fogdeployid}'"}' | jq -r '.count')

    # If there are scheduled or active deploy tasks, pause the queue and let them finish.
    if [ $deploytasks -gt 0 ]; then
      for type in $MACHINETYPES; do
        # Only pause the queue for 1hr just in case anything goes wrong with the Jenkins job.
        teuthology-queue --pause 3600 --machine_type $type
      done
      pausedqueue=true
      currentretries=0
      while [ $deploytasks -gt 0 ]; do
        echo "$(date) -- $deploytasks FOG deploy tasks still queued.  Sleeping 10sec"
        sleep 10
        deploytasks=$(funFogApi GET /task/active '{"typeID": "'${fogdeployid}'"}' | jq -r '.count')
        ((++currentretries))
        # Retry for 1hr
        funRetry $currentretries 360
      done
    fi
  fi

  # Create a capture task for each host and reboot it so FOG captures its OS
  while read -u3 -r host distro foghostid fogimageid deployed; do
    funFogApi PUT /host/$foghostid '{"imageID": "'${fogimageid}'"}'
    funFogApi POST /host/$foghostid/task '{"taskTypeID": "'${fogcaptureid}'"}'
    if [ "$FSCKMETHOD" == "maas-rescue" ]; then
      # Exiting rescue mode reboots the host and keeps MAAS's state sane
      systemid=$(maas $maasprofile machines read hostname=$host | jq -r '.[0].system_id')
      maas $maasprofile machine exit-rescue-mode $systemid
    else
      funReboot $host
    fi
  done 3< $statefile

  # Wait for Capture tasks to finish
  capturetasks=$(funFogApi GET /task/active '{"typeID": "'${fogcaptureid}'"}' | jq -r '.count')
  currentretries=0
  while [ $capturetasks -gt 0 ]; do
    echo "$(date) -- $capturetasks FOG capture tasks still queued.  Sleeping 10sec"
    sleep 10
    capturetasks=$(funFogApi GET /task/active '{"typeID": "'${fogcaptureid}'"}' | jq -r '.count')
    ((++currentretries))
    # Retry for 30min
    funRetry $currentretries 180
  done

  # Unpause the queue if we paused it earlier
  if [ "$pausedqueue" = true ]; then
    for type in $MACHINETYPES; do
      teuthology-queue --pause 0 --machine_type $type
    done
  fi
}

phase_unlock () {
  funActivateVenv

  if [ "$use_teuthologylock" = true ]; then
    # Unlock all machines after all capture images are finished
    for host in $(funAllHosts); do
      teuthology-lock --update --status up $host
    done
  fi
}

phase_cleanup () {
  # Best-effort cleanup after a failed or aborted run:
  # - Points dnsmasq PXE entries back at FOG
  # - Deletes any active FOG Capture/Deploy tasks created by the job
  # - Takes hosts out of MAAS rescue mode if they were left there
  # - Unpauses the teuthology queue
  # - Unlocks the testnodes
  funActivateVenv

  allhosts=$(funAllHosts)

  # Everything from here on is best-effort cleanup
  set +e

  if [ "$FSCKMETHOD" == "maas-rescue" ]; then
    # Point dnsmasq PXE entries back at FOG (harmless if they already are)
    for machine in $allhosts; do
      funSetPxe $machine fog
    done

    # Take hosts out of rescue mode if they were left there
    if command -v maas >/dev/null 2>&1 && [ -n "$MAAS_API_KEY" ]; then
      { set +x; } 2>/dev/null
      maas login $maasprofile $maasurl "$MAAS_API_KEY"
      set -x
      for machine in $allhosts; do
        systemid=$(maas $maasprofile machines read hostname=$machine | jq -r '.[0].system_id')
        if [ "$systemid" != "null" ] && [ -n "$systemid" ]; then
          status=$(maas $maasprofile machine read $systemid | jq -r '.status_name')
          if [ "$status" == "Rescue mode" ] || [ "$status" == "Entering rescue mode" ]; then
            maas $maasprofile machine exit-rescue-mode $systemid
          fi
        fi
      done
    fi
  fi

  # Delete all active Capture and Deploy tasks
  for tasktype in Capture Deploy; do
    tasktypeid=$(funFogApi GET /tasktype '{"name": "'${tasktype}'"}' | jq -r '.tasktypes[0].id')
    for task in $(funFogApi GET /task/active '{"typeID": "'${tasktypeid}'"}' | jq -r '(.tasks // [])[].id'); do
      funFogApi DELETE /task/${task}
    done
  done

  # Unpause the queue.  (We can't tell whether the capture phase actually
  # paused it, and unpausing unconditionally is safe.)
  if [ "$PAUSEQUEUE" == "true" ]; then
    for type in $MACHINETYPES; do
      teuthology-queue --pause 0 --machine_type $type
    done
  fi

  if [ "$use_teuthologylock" = true ]; then
    # Unlock all machines
    for host in $allhosts; do
      teuthology-lock --update --status up $host
    done
  fi

  return 0
}

case "$1" in
  prepare|lock|deploy|ansible|fsck|capture|unlock|cleanup)
    cd $WORKSPACE
    phase_$1
    ;;
  *)
    echo "Usage: $0 {prepare|lock|deploy|ansible|fsck|capture|unlock|cleanup}"
    exit 1
    ;;
esac
