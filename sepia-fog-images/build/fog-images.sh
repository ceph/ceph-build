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
#   fog-images.sh verify    Deploy the new images on different hosts to prove
#                           they work, then unpause the queue
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

# Wait until a host has finished its first-boot network/hostname
# configuration (the sentinel file).  Usage: funWaitForHost <host> [maxretries]
funWaitForHost () {
  local currentretries=0
  until ssh $sshopts ubuntu@${1}.front.sepia.ceph.com "stat $sentinelfile > /dev/null 2>&1"; do
    echo "$(date) -- ${1} has not created $sentinelfile yet.  Sleeping 30sec"
    sleep 30
    ((++currentretries))
    funRetry $currentretries ${2:-60}
  done
}

# Wait until none of the given FOG host IDs have active tasks.
# Usage: funWaitForOurTasks '["1","2"]' [maxretries]
funWaitForOurTasks () {
  local currentretries=0 activetasks
  while true; do
    activetasks=$(funFogApi GET /task/active | jq -r --argjson ids "$1" '[(.tasks // [])[] | select((.hostID|tostring) as $h | $ids | index($h))] | length')
    if [ "${activetasks:-1}" == "0" ]; then
      break
    fi
    echo "$(date) -- $activetasks FOG tasks for our hosts still active.  Sleeping 30sec"
    sleep 30
    ((++currentretries))
    funRetry $currentretries ${2:-120}
  done
}

# Mark down one free host of the given machine type for image verification.
# Prints the claimed short hostname.  Usage: funClaimExtraHost <type>
funClaimExtraHost () {
  local currentretries=0 candidate
  while true; do
    candidate=$(teuthology-lock --brief -a --machine-type $1 --status up --locked false | head -n 1 | awk '{ print $1 }')
    if [ -n "$candidate" ] && teuthology-lock --update --status down --desc "$lockdesc" $candidate >&2; then
      echo $candidate | cut -d '.' -f1
      return 0
    fi
    sleep 5
    ((++currentretries))
    # Retry for 20min
    funRetry $currentretries 240
  done
}

# Should we use teuthology-lock to lock systems?
if [ "$DEFINEDHOSTS" == "" ]; then
  use_teuthologylock=true
else
  use_teuthologylock=false
fi

numdistros=$(echo $DISTROS | wc -w)

# IMAGETYPE overrides the machine-type prefix of the FOG image names, e.g.
# MACHINETYPES=trial IMAGETYPE=trial-perf locks trial nodes but deploys and
# recaptures trial-perf_<distro> images.  Empty means images are named after
# the machine type.
# The queue is paused for the machine types being used AND the type whose
# images are being rewritten.
pausetypes="$MACHINETYPES${IMAGETYPE:+ $IMAGETYPE}"

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

  # Keep trying to claim machines until we have one per distro.  We mark them
  # down with a descriptive desc instead of locking because locking attempts
  # to reimage using FOG.
  for type in $MACHINETYPES; do
    currentretries=0
    while true; do
      numlocked=$(teuthology-lock --brief -a --machine-type $type --status down | grep -c "$lockdesc")
      [ "$numlocked" -ge "$numdistros" ] && break
      candidate=$(teuthology-lock --brief -a --machine-type $type --status up --locked false | head -n 1 | awk '{ print $1 }')
      if [ -z "$candidate" ] || ! teuthology-lock --update --status down --desc "$lockdesc" $candidate; then
        # Nothing free or the claim failed; don't hammer the lock server
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
      lockedhosts=$(echo $DEFINEDHOSTS | tr ' ' '\n' | grep "^${type}" || true)
    fi
    # Create arrays using our lists so we can iterate through them
    array1=($lockedhosts)
    array2=($DISTROS)
    for i in $(seq 1 $numdistros); do
      host=${array1[$i-1]}
      if [ -z "$host" ]; then
        echo "ERROR: Fewer $type hosts than distros ($numdistros needed)"
        exit 1
      fi
      funSetProfiles ${array2[$i-1]}
      imagename="${IMAGETYPE:-$type}_${fogprofile}"
      # Get FOG host ID
      foghostid=$(funFogApi GET /host '{"name": "'${host}'"}' | jq -r '.hosts[0].id')
      if [ -z "$foghostid" ] || [ "$foghostid" == "null" ]; then
        echo "ERROR: $host is not registered in FOG at http://${fogserver}/fog"
        exit 1
      fi
      # Get FOG image ID
      fogimageid=$(funFogApi GET /image '{"name": "'${imagename}'"}' | jq -r '.images[0].id')
      deployed=false
      if [ "$fogimageid" == "null" ] || [ -z "$fogimageid" ]; then
        if [ "$use_teuthologylock" = true ]; then
          # Nothing to deploy.  Brand new distros have to be seeded manually:
          # image a host by hand, then rerun this job with DEFINEDHOSTS
          # pointing at it.
          echo "ERROR: No FOG image named ${imagename} exists so there is nothing to deploy and update."
          echo "Seed the first ${imagename} image manually, then rerun this job with DEFINEDHOSTS set."
          exit 1
        fi
        # DEFINEDHOSTS path: the host is assumed to already be running the
        # target OS.  Create the image template so it can be captured.
        funFogApi POST /image/ '{ "imageTypeID": "1", "imagePartitionTypeID": "1", "name": "'${imagename}'", "path": "'${imagename}'", "osID": "50", "format": "0", "magnet": "", "protected": "0", "compress": "6", "isEnabled": "1", "toReplicate": "1", "os": {"id": "50", "name": "Linux", "description": ""}, "imagepartitiontype": {"id": "1", "name": "Everything", "type": "all"}, "imagetype": {"id": "1", "name": "Single Disk - Resizable", "type": "n"}, "imagetypename": "Single Disk - Resizable", "imageparttypename": "Everything", "osname": "Linux", "storagegroupname": "default"}' || true
        fogimageid=$(funFogApi GET /image '{"name": "'${imagename}'"}' | jq -r '.images[0].id')
      elif [ "$SKIPDEPLOY" == "true" ]; then
        echo "SKIPDEPLOY set; capturing ${host}'s current OS as ${imagename} without redeploying first"
      else
        # Associate the image with the host and deploy it
        funFogApi PUT /host/$foghostid '{"imageID": "'${fogimageid}'"}'
        funFogApi POST /host/$foghostid/task '{"taskTypeID": "'${fogdeployid}'"}'
        funReboot $host
        deployed=true
      fi
      echo "$host ${array2[$i-1]} $foghostid $fogimageid $deployed $type" >> $statefile
    done
  done

  # Wait for all of our deploy tasks to finish (single API call per poll)
  deployids=$(awk '$5 == "true" {print $3}' $statefile | jq -R . | jq -sc .)
  funWaitForOurTasks "$deployids" 120

  # Wait for the freshly-deployed hosts to come back up and finish their
  # first-boot network/hostname configuration (the sentinel file)
  while read -u3 -r host distro foghostid fogimageid deployed type; do
    [ "$deployed" == "true" ] || continue
    funWaitForHost $host 60
  done 3< $statefile
}

phase_ansible () {
  funActivateVenv

  # Bring the testnodes fully up to date, then prep them for capture.  One
  # ansible run covering every host so they're configured in parallel.
  # set ANSIBLE_CONFIG to allow teuthology to specify collections dir
  limit=$(awk '{printf "%s%s*", (NR > 1 ? ":" : ""), $1}' $statefile)
  ANSIBLE_CONFIG=$WORKSPACE/teuthology/ansible.cfg ansible-playbook $WORKSPACE/ceph-cm-ansible/cephlab.yml -e ansible_ssh_user=ubuntu --limit="$limit"
  ANSIBLE_CONFIG=$WORKSPACE/teuthology/ansible.cfg ansible-playbook $WORKSPACE/ceph-cm-ansible/tools/prep-fog-capture.yml -e ansible_ssh_user=ubuntu --limit="$limit"
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
  while read -u3 -r host distro foghostid fogimageid deployed type; do
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

  # Pause the queue for the whole capture+verify window: captures replace the
  # image the queue deploys from, and the new image is unusable until the
  # verify phase has proven it boots.  The 2h expiry is a safety valve in
  # case this job dies without running cleanup.
  if [ "$PAUSEQUEUE" == "true" ]; then
    for qtype in $pausetypes; do
      teuthology-queue --pause 7200 --machine_type $qtype
    done

    # Let any already-scheduled deploys drain before we start capturing
    deploytasks=$(funFogApi GET /task/active '{"typeID": "'${fogdeployid}'"}' | jq -r '.count // 0')
    currentretries=0
    while [ "${deploytasks:-0}" -gt 0 ]; do
      echo "$(date) -- $deploytasks FOG deploy tasks still queued.  Sleeping 10sec"
      sleep 10
      deploytasks=$(funFogApi GET /task/active '{"typeID": "'${fogdeployid}'"}' | jq -r '.count // 0')
      ((++currentretries))
      # Retry for 1hr
      funRetry $currentretries 360
    done
  fi

  # From this point on the images are being rewritten; the cleanup phase uses
  # this marker to know it must NOT unpause the queue on failure.
  touch $WORKSPACE/captures-started

  # Create a capture task for each host and reboot it so FOG captures its OS
  while read -u3 -r host distro foghostid fogimageid deployed type; do
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
  capturetasks=$(funFogApi GET /task/active '{"typeID": "'${fogcaptureid}'"}' | jq -r '.count // 0')
  currentretries=0
  while [ "${capturetasks:-1}" -gt 0 ]; do
    echo "$(date) -- $capturetasks FOG capture tasks still queued.  Sleeping 10sec"
    sleep 10
    capturetasks=$(funFogApi GET /task/active '{"typeID": "'${fogcaptureid}'"}' | jq -r '.count // 0')
    ((++currentretries))
    # Retry for 30min
    funRetry $currentretries 180
  done
  # NOTE: the queue deliberately stays paused here; the verify phase unpauses
  # it once the new images have been proven to boot.
}

phase_verify () {
  # Deploy each freshly-captured image onto a *different* host than it was
  # captured from and make sure it boots, finishes first-boot configuration,
  # and takes on the right hostname.  Only then is it safe to unpause the
  # queue.  With multiple distros per machine type the capture hosts verify
  # each other's images (rotation); with a single distro we claim one extra
  # host of that type.
  funActivateVenv

  fogdeployid=$(funFogApi GET /tasktype '{"name": "Deploy"}' | jq -r '.tasktypes[0].id')

  verifyfile="$WORKSPACE/fog-verify.state"
  rm -f $verifyfile
  touch $verifyfile
  extrahosts=""

  for type in $MACHINETYPES; do
    typehosts=($(awk -v t="$type" '$6 == t {print $1}' $statefile))
    typeimages=($(awk -v t="$type" '$6 == t {print $4}' $statefile))
    typedistros=($(awk -v t="$type" '$6 == t {print $2}' $statefile))
    n=${#typehosts[@]}
    [ $n -eq 0 ] && continue
    for i in $(seq 0 $((n - 1))); do
      if [ $n -ge 2 ]; then
        # Rotate: host i+1 verifies the image captured on host i
        target=${typehosts[$(( (i + 1) % n ))]}
      elif [ "$use_teuthologylock" = true ]; then
        target=$(funClaimExtraHost $type) || {
          echo "ERROR: Could not claim a $type host to verify ${typedistros[$i]}.  Queue stays paused."
          exit 1
        }
        extrahosts="$extrahosts $target"
      else
        # DEFINEDHOSTS with a single host: redeploying onto the same host is
        # a weaker test (it can't catch host-specific leakage) but still
        # proves the image boots.
        echo "WARNING: Only one $type host defined; verifying ${typedistros[$i]} on the host it was captured from."
        target=${typehosts[$i]}
      fi
      targetid=$(funFogApi GET /host '{"name": "'${target}'"}' | jq -r '.hosts[0].id')
      if [ -z "$targetid" ] || [ "$targetid" == "null" ]; then
        echo "ERROR: verify host $target is not registered in FOG.  Queue stays paused."
        exit 1
      fi
      funFogApi PUT /host/$targetid '{"imageID": "'${typeimages[$i]}'"}'
      funFogApi POST /host/$targetid/task '{"taskTypeID": "'${fogdeployid}'"}'
      funReboot $target
      echo "$target ${typedistros[$i]} $targetid" >> $verifyfile
    done
  done

  # Wait for the verify deploys to finish, then for first-boot config
  verifyids=$(awk '{print $3}' $verifyfile | jq -R . | jq -sc .)
  funWaitForOurTasks "$verifyids" 120

  while read -u3 -r target distro targetid; do
    funWaitForHost $target 60
    # The deployed host must come up as itself, not as the capture host
    actualhostname=$(ssh $sshopts ubuntu@${target}.front.sepia.ceph.com "hostname -s")
    if [ "$actualhostname" != "$target" ]; then
      echo "ERROR: $target booted the new $distro image with hostname '$actualhostname'.  Queue stays paused."
      exit 1
    fi
    echo "Verified: $distro image boots and configures correctly on $target"
  done 3< $verifyfile

  # Release any extra hosts we claimed just for verification
  for host in $extrahosts; do
    teuthology-lock --update --status up $host
  done

  # The new images are good; the queue can deploy them again
  if [ "$PAUSEQUEUE" == "true" ]; then
    for qtype in $pausetypes; do
      teuthology-queue --pause 0 --machine_type $qtype
    done
  fi
  rm -f $WORKSPACE/captures-started
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

  # Queue handling depends on how far we got.  If captures started but were
  # never verified, the images may be broken and every reimage would fail:
  # keep the queue paused (re-up the 2h pause to give an admin time to look).
  # Before any capture started the old images are intact, so unpause.
  if [ "$PAUSEQUEUE" == "true" ]; then
    if [ -f $WORKSPACE/captures-started ]; then
      echo "WARNING: Captures started but the new image(s) were never verified."
      echo "WARNING: LEAVING the teuthology queue paused for: $pausetypes"
      echo "WARNING: Verify or restore the images, then unpause with: teuthology-queue --pause 0 --machine_type <type>"
      for qtype in $pausetypes; do
        teuthology-queue --pause 7200 --machine_type $qtype
      done
    else
      for qtype in $pausetypes; do
        teuthology-queue --pause 0 --machine_type $qtype
      done
    fi
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
  prepare|lock|deploy|ansible|fsck|capture|verify|unlock|cleanup)
    cd $WORKSPACE
    phase_$1
    ;;
  *)
    echo "Usage: $0 {prepare|lock|deploy|ansible|fsck|capture|verify|unlock|cleanup}"
    exit 1
    ;;
esac
