#!/bin/bash
# All the logic for the sepia-fog-images pipeline.  The Jenkinsfile calls
# this script once per stage with a phase argument:
#
#   fog-images.sh prepare   Clone/bootstrap teuthology and ceph-cm-ansible
#   fog-images.sh lock      Pause the teuthology queue and lock testnodes
#                           (locking skipped when DEFINEDHOSTS is set)
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

# FOG host IDs for the given machine types, as a JSON array of strings.
# Testnodes are named <type><NNN> (trial059, smithi042), so anchor the match:
# a bare "trial" prefix would also swallow trial-perf hosts.
# Usage: funTypeHostIds <type>...
funTypeHostIds () {
  funFogApi GET /host | jq -c --arg types "$*" '
    ($types | split(" ") | map(select(length > 0))) as $t
    | [ (.hosts // [])[]
        | select(.name as $n | $t | any(. as $p | $n | test("^\($p)[0-9]+$")))
        | .id | tostring ]'
}

# Count active tasks of one type whose host is in the given JSON ID array.
# Usage: funCountTasksFor <tasktypeid> '["1","2"]'
funCountTasksFor () {
  funFogApi GET /task/active '{"typeID": "'${1}'"}' \
    | jq -r --argjson ids "$2" '[(.tasks // [])[] | select((.hostID|tostring) as $h | $ids | index($h))] | length'
}

# Does a FOG image have captured content?  FOG only fills in an image's
# "size" when a capture has completed, so a record without one is just a
# template (or a capture that never happened) and must not be deployed.
# Usage: funImageHasContent <imageid>
funImageHasContent () {
  local size
  size=$(funFogApi GET /image/$1 | jq -r '.size // ""')
  [ -n "$size" ] && [ "$size" != "null" ]
}

# Print the ID of a usable (captured) FOG image by name, or nothing.
# Usage: funUsableImageId <imagename>
funUsableImageId () {
  local id
  id=$(funFogApi GET /image '{"name": "'${1}'"}' | jq -r '.images[0].id // ""')
  if [ -n "$id" ] && [ "$id" != "null" ] && funImageHasContent $id; then
    echo $id
  fi
}

# For a major-only distro (rocky_10) with no usable ${type}_rocky_10 image
# yet, find the newest captured point-release image of that major
# (${type}_rocky_10.2 over ${type}_rocky_10.1) to seed it from.  Prints
# "<id> <name>" or nothing.  Usage: funNewestMinorImage <type> <distro> <major>
funNewestMinorImage () {
  local name id
  name=$(funFogApi GET /image/search/"${1}_${2}_${3}." \
    | jq -r --arg p "${1}_${2}_${3}." '[(.images // [])[] | select(.name | startswith($p)) | select((.size // "") != "") | .name] | .[]' \
    | sort -V | tail -n 1)
  [ -n "$name" ] || return 0
  id=$(funFogApi GET /image '{"name": "'${name}'"}' | jq -r '.images[0].id // ""')
  if [ -n "$id" ] && [ "$id" != "null" ]; then
    echo "$id $name"
  fi
  return 0
}

# FOG's per-host "deployed" timestamp is only bumped when a deploy task
# completes successfully, so it tells a real deploy apart from a task that
# was cancelled or died in FOS (after which the node just boots whatever
# was on its disk).  Usage: funHostDeployedAt <foghostid>
funHostDeployedAt () {
  funFogApi GET /host/$1 | jq -r '.deployed // ""'
}

# Check that a host is actually running the distro we think it is, by
# /etc/os-release.  A major-only version (rocky_10) accepts any point
# release of that major; a full version must match exactly; centos stream
# reports only the major.  Usage: funCheckHostOs <host> <distro>
funCheckHostOs () {
  local host=$1 want=$2 wantid wantver osrel gotid gotver gotmajor wantmajor
  wantid=$(echo $want | cut -d '_' -f1)
  wantver=$(echo $want | cut -d '_' -f2)
  osrel=$(ssh $sshopts ubuntu@${host}.front.sepia.ceph.com "cat /etc/os-release") || {
    echo "ERROR: could not read /etc/os-release on $host"
    return 1
  }
  gotid=$(echo "$osrel" | sed -n 's/^ID="\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' | head -n 1)
  gotver=$(echo "$osrel" | sed -n 's/^VERSION_ID="\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' | head -n 1)
  case "$gotid" in
    almalinux) gotid=alma ;;
    opensuse-leap|opensuse-tumbleweed|sles) gotid=opensuse ;;
  esac
  gotmajor=${gotver%%.*}
  wantmajor=${wantver%%.*}
  case "$wantver" in
    *stream) wantver=$wantmajor ;;
  esac
  if [ "$gotid" != "$wantid" ]; then
    echo "ERROR: $host is running $gotid $gotver, not $want"
    return 1
  fi
  if [ "$wantver" == "$wantmajor" ]; then
    # major-only request: any point release of that major will do
    [ "$gotmajor" == "$wantmajor" ] || { echo "ERROR: $host is running $gotid $gotver, not $want"; return 1; }
  else
    [ "$gotver" == "$wantver" ] || { echo "ERROR: $host is running $gotid $gotver, not $want"; return 1; }
  fi
  echo "$host is running $gotid $gotver as expected for $want"
}

# Claiming testnodes.
#
# Marking a node down is not a claim: it is not atomic against lock_many, and
# build #6 (2026-08-20) picked trial059 out of "--status up --locked false" in
# the 20s gap between one scheduled job releasing it and the next one locking
# it, so the pipeline and a teuthology job FOG-deployed the same host and the
# ansible phase died with UNREACHABLE.  Take a real paddles lock instead --
# atomic, owned by the Jenkins user, so lock_many cannot hand the node out
# from under us -- and mark it down as well.
#
# --no-reimage (ceph/teuthology#2250) is what makes --lock usable here: by
# default it reimages bare-metal nodes whose machine_type is a reimage type,
# which is the opposite of what phase_deploy wants.

# Usage: funClaim <fqdn>.  Nonzero if somebody else locked it first.
funClaim () {
  teuthology-lock --lock --no-reimage --desc "$lockdesc" "$1" || return 1
  teuthology-lock --update --status down --desc "$lockdesc" "$1"
}

# Usage: funRelease <host>...  Put nodes back in the pool: status up, then
# drop the lock.  --unlock powers a FOG-type node off on its way out; that's
# fine, the queue's next reimage power-cycles it anyway.  -f releases the
# rest even if one host fails (still exits nonzero).
funRelease () {
  if [ $# -eq 0 ]; then
    return 0
  fi
  local host
  for host in "$@"; do
    teuthology-lock --update --status up $host
  done
  teuthology-lock --unlock -f "$@"
}

# The hosts this build has claimed, one short hostname per line.
# Usage: funClaimedHosts [machine-type]
#
# Keyed off the lock owner and description, not "--status down": another job's
# reimage flips a node back up behind our back, and in build #6 that is how
# the cleanup phase lost track of trial059 and left it claimed.  --brief with
# neither -a nor --owner already filters to the invoking user's locks.
funClaimedHosts () {
  # --brief rows are "<fqdn> up|down locked|unlocked <owner> "<desc>"".  Match
  # on the status column so a stray line can never be read back as a hostname.
  teuthology-lock --brief --desc-pattern "$lockdesc" ${1:+--machine-type $1} |
    awk '$2 == "up" || $2 == "down" { print $1 }' | cut -d '.' -f1
}

# Free hosts of the given machine type, one FQDN per line, sorted by name.
# Usage: funFreeHosts <machine-type>
funFreeHosts () {
  teuthology-lock --brief -a --machine-type $1 --status up --locked false |
    awk '$2 == "up" { print $1 }'
}

# Usage: funPauseQueue <seconds>.  0 unpauses.  No-op unless PAUSEQUEUE.
funPauseQueue () {
  if [ "$PAUSEQUEUE" == "true" ]; then
    for qtype in $pausetypes; do
      teuthology-queue --pause $1 --machine_type $qtype
    done
  fi
}

# Claim one free host of the given machine type for image verification.
# Prints the claimed short hostname.  Usage: funClaimExtraHost <type>
funClaimExtraHost () {
  local currentretries=0 candidate
  while true; do
    # Walk the whole free list: a claim can lose the race to the queue, and
    # retrying the same head-of-list host forever would just burn the timeout
    for candidate in $(funFreeHosts $1); do
      if funClaim $candidate >&2; then
        echo $candidate | cut -d '.' -f1
        return 0
      fi
    done
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
    funClaimedHosts | tr "\n" " "
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
  funActivateVenv

  # Pause the queue before claiming anything, not at capture time.  funClaim
  # is atomic, but a live dispatcher still races us for every node the queue
  # frees, and the job that wins that race reimages a host this build is in
  # the middle of using (build #6, 2026-08-20).  Paused, nodes only ever come
  # free towards us.  The 2h expiry is a safety valve in case this job dies
  # without running cleanup.
  funPauseQueue 7200

  if [ "$use_teuthologylock" != true ]; then
    echo "DEFINEDHOSTS set; skipping locking"
    return 0
  fi

  # Don't bail if we fail to lock machines
  set +e

  # Keep trying to claim machines until we have one per distro
  for type in $MACHINETYPES; do
    currentretries=0
    while true; do
      numlocked=$(funClaimedHosts $type | wc -l | tr -d '[:space:]')
      [ "$numlocked" -ge "$numdistros" ] && break
      claimed=false
      for candidate in $(funFreeHosts $type); do
        if funClaim $candidate; then
          claimed=true
          break
        fi
      done
      if [ "$claimed" != true ]; then
        # Nothing free, or the queue beat us to every free node; don't
        # hammer paddles
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
      lockedhosts=$(funClaimedHosts $type | sort)
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
      # The node is provisioned with its own machine type's image and the
      # result is captured under IMAGETYPE's name (they're the same unless
      # IMAGETYPE is set, e.g. deploy trial_X on a trial node, capture it
      # back as trial-perf_X)
      deployimagename="${type}_${fogprofile}"
      captureimagename="${IMAGETYPE:-$type}_${fogprofile}"
      # Get FOG host ID
      foghostid=$(funFogApi GET /host '{"name": "'${host}'"}' | jq -r '.hosts[0].id')
      if [ -z "$foghostid" ] || [ "$foghostid" == "null" ]; then
        echo "ERROR: $host is not registered in FOG at http://${fogserver}/fog"
        exit 1
      fi
      # Work out what to deploy BEFORE touching the capture image.  On a
      # first capture the deploy and capture names are the same, and build
      # #4 (2026-08-19) created the empty capture template first, then
      # "found" it as the deploy image and deployed it: FOS had nothing to
      # restore, the node booted whatever was on its disk (an Ubuntu
      # install), and the job captured that as trial_rocky_10.  Only an
      # image FOG has a size for counts as deployable.
      deployimageid=$(funUsableImageId $deployimagename)
      seedsearched=false
      if [ -z "$deployimageid" ] && [ "$distroversion" == "${distroversion%%.*}" ]; then
        # Major-only distro (rocky_10) with no captured image yet: seed it
        # from the newest captured point-release image of that major.  The
        # ansible phase passes rocky_upgrade_scope=major for this distro, so
        # prep-fog-capture walks the seed to the newest minor against the
        # major tree before we capture it as ${deployimagename}.
        seedsearched=true
        seed=$(funNewestMinorImage $type $splitdistro $distroversion)
        if [ -n "$seed" ]; then
          deployimageid=${seed%% *}
          echo "No captured ${deployimagename} image; seeding it from ${seed#* } (image ${deployimageid})"
          echo "prep-fog-capture will upgrade it to the newest ${splitdistro} ${distroversion} minor before capture"
        else
          echo "No captured ${deployimagename} image and no ${type}_${splitdistro}_${distroversion}.* point release to seed it from"
        fi
      fi
      # Make sure the image we'll capture into exists, creating the template
      # if this is its first capture
      captureimageid=$(funFogApi GET /image '{"name": "'${captureimagename}'"}' | jq -r '.images[0].id')
      if [ "$captureimageid" == "null" ] || [ -z "$captureimageid" ]; then
        funFogApi POST /image/ '{ "imageTypeID": "1", "imagePartitionTypeID": "1", "name": "'${captureimagename}'", "path": "'${captureimagename}'", "osID": "50", "format": "0", "magnet": "", "protected": "0", "compress": "6", "isEnabled": "1", "toReplicate": "1", "os": {"id": "50", "name": "Linux", "description": ""}, "imagepartitiontype": {"id": "1", "name": "Everything", "type": "all"}, "imagetype": {"id": "1", "name": "Single Disk - Resizable", "type": "n"}, "imagetypename": "Single Disk - Resizable", "imageparttypename": "Everything", "osname": "Linux", "storagegroupname": "default"}' || true
        captureimageid=$(funFogApi GET /image '{"name": "'${captureimagename}'"}' | jq -r '.images[0].id')
        if [ "$captureimageid" == "null" ] || [ -z "$captureimageid" ]; then
          echo "ERROR: Could not create FOG image template ${captureimagename}"
          exit 1
        fi
      fi
      deployed=false
      deployedat=""
      if [ -z "$deployimageid" ]; then
        if [ "$use_teuthologylock" = true ]; then
          # Nothing to deploy.  Brand new distros for a machine type have to
          # be seeded manually: image a host by hand, then rerun this job
          # with DEFINEDHOSTS pointing at it.
          if [ "$seedsearched" == true ]; then
            echo "ERROR: No captured FOG image named ${deployimagename} exists, and FOG has no captured ${type}_${splitdistro}_${distroversion}.* point-release image to seed it from."
          else
            echo "ERROR: No captured FOG image named ${deployimagename} exists so there is nothing to deploy and update."
          fi
          echo "Seed the first ${deployimagename} image manually, then rerun this job with DEFINEDHOSTS set."
          exit 1
        fi
        # DEFINEDHOSTS path: the host must already be running the target
        # OS -- check, don't assume
        echo "No captured ${deployimagename} image to deploy; capturing ${host}'s current OS"
        funCheckHostOs $host ${array2[$i-1]} || exit 1
      elif [ "$SKIPDEPLOY" == "true" ]; then
        echo "SKIPDEPLOY set; capturing ${host}'s current OS as ${captureimagename} without redeploying first"
        funCheckHostOs $host ${array2[$i-1]} || exit 1
      else
        # Associate the image with the host and deploy it
        deployedat=$(funHostDeployedAt $foghostid)
        funFogApi PUT /host/$foghostid '{"imageID": "'${deployimageid}'"}'
        funFogApi POST /host/$foghostid/task '{"taskTypeID": "'${fogdeployid}'"}'
        funReboot $host
        deployed=true
      fi
      echo "$host ${array2[$i-1]} $foghostid $captureimageid $deployed $type ${deployedat:-none}" >> $statefile
    done
  done

  # Wait for all of our deploy tasks to finish (single API call per poll)
  deployids=$(awk '$5 == "true" {print $3}' $statefile | jq -R . | jq -sc .)
  funWaitForOurTasks "$deployids" 120

  # A task leaving the active list only means it is gone, not that it
  # worked: FOG bumps the host's "deployed" timestamp only on success.
  while read -u3 -r host distro foghostid fogimageid deployed type deployedat; do
    [ "$deployed" == "true" ] || continue
    if [ "$(funHostDeployedAt $foghostid)" == "$deployedat" ]; then
      echo "ERROR: FOG never recorded a successful deploy for $host (deployed timestamp still '${deployedat}'); the deploy task failed or was cancelled.  Not continuing with whatever is on its disk."
      exit 1
    fi
  done 3< $statefile

  # Wait for the freshly-deployed hosts to come back up and finish their
  # first-boot network/hostname configuration (the sentinel file), then
  # make sure they booted the OS we deployed and not a leftover install
  while read -u3 -r host distro foghostid fogimageid deployed type deployedat; do
    [ "$deployed" == "true" ] || continue
    funWaitForHost $host 60
    funCheckHostOs $host $distro || exit 1
  done 3< $statefile
}

phase_ansible () {
  funActivateVenv

  # Bring the testnodes fully up to date, then prep them for capture.  One
  # cephlab run covering every host so they're configured in parallel.
  # set ANSIBLE_CONFIG to allow teuthology to specify collections dir
  limit=$(awk '{printf "%s%s*", (NR > 1 ? ":" : ""), $1}' $statefile)
  ANSIBLE_CONFIG=$WORKSPACE/teuthology/ansible.cfg ansible-playbook $WORKSPACE/ceph-cm-ansible/cephlab.yml -e ansible_ssh_user=ubuntu --limit="$limit"

  # prep-fog-capture runs per host: a minor-named capture (rocky_10.1) must
  # stay on its minor (the testnode role pins the repos), while a
  # major-tracking one (rocky_10) walks to the newest minor first
  while read -u3 -r host distro foghostid fogimageid deployed type deployedat; do
    ver=${distro##*_}
    scope=minor
    [ "$ver" == "${ver%%.*}" ] && scope=major
    ANSIBLE_CONFIG=$WORKSPACE/teuthology/ansible.cfg ansible-playbook $WORKSPACE/ceph-cm-ansible/tools/prep-fog-capture.yml -e ansible_ssh_user=ubuntu -e rocky_upgrade_scope=$scope --limit="${host}*"
  done 3< $statefile
}

phase_fsck () {
  # fsck the root filesystems so FOG's partclone/resize2fs are working with
  # clean filesystems when the capture runs
  if [ "$FSCKMETHOD" == "fog-postinit" ]; then
    # Nothing to do here: the fog-server role in ceph-cm-ansible installs a
    # postinit hook on ${fogserver} that fscks the disk inside the FOS
    # environment right before every capture
    echo "fsck happens via the fog-server postinit hook on ${fogserver} during capture"
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
  while read -u3 -r host distro foghostid fogimageid deployed type deployedat; do
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

  # phase_lock already paused the queue; re-arm the 2h expiry so it covers
  # the capture+verify window too.  Captures replace the image the queue
  # deploys from, and the new image is unusable until the verify phase has
  # proven it boots.
  funPauseQueue 7200

  if [ "$PAUSEQUEUE" == "true" ]; then
    # Let any already-scheduled deploys drain before we start capturing, but
    # only the ones that could be deploying an image we are about to
    # overwrite.  A busy trial queue is no reason to hold up a smithi
    # capture, and the whole-server count used to block on exactly that.
    drainhostids=$(funTypeHostIds $pausetypes)
    if [ -z "$drainhostids" ] || [ "$drainhostids" == "[]" ]; then
      # phase_deploy resolved a FOG host for every one of these types, so an
      # empty list here means the host query failed, not that the lab is idle
      echo "ERROR: Could not list FOG hosts for: $pausetypes"
      exit 1
    fi
    deploytasks=$(funCountTasksFor $fogdeployid "$drainhostids")
    currentretries=0
    while [ "${deploytasks:-0}" -gt 0 ]; do
      echo "$(date) -- $deploytasks FOG deploy tasks still queued for $pausetypes.  Sleeping 10sec"
      sleep 10
      deploytasks=$(funCountTasksFor $fogdeployid "$drainhostids")
      ((++currentretries))
      # Retry for 1hr
      funRetry $currentretries 360
    done
  fi

  # From this point on the images are being rewritten; the cleanup phase uses
  # this marker to know it must NOT unpause the queue on failure.
  touch $WORKSPACE/captures-started

  # Create a capture task for each host and reboot it so FOG captures its OS
  while read -u3 -r host distro foghostid fogimageid deployed type deployedat; do
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
  funWaitForCaptureTasks

  # A major-tracking distro (rocky_10) is also captured under the point
  # release the host is actually running (trial_rocky_10.2), so jobs that
  # pin a minor can keep getting exactly that minor after the major image
  # moves on.  Second capture task, own image record and files.
  twincaptures=false
  while read -u3 -r host distro foghostid fogimageid deployed type deployedat; do
    ver=${distro##*_}
    [ "$ver" == "${ver%%.*}" ] || continue
    funWaitForHost $host 60
    minor=$(ssh $sshopts ubuntu@${host}.front.sepia.ceph.com "sed -n 's/^VERSION_ID=\"\{0,1\}\([^\"]*\)\"\{0,1\}$/\1/p' /etc/os-release" | head -n 1)
    if [ -z "$minor" ] || [ "$minor" == "${minor%%.*}" ]; then
      echo "WARNING: no point release readable on $host; not capturing a minor-named twin of $distro"
      continue
    fi
    majorname=$(funFogApi GET /image/$fogimageid | jq -r '.name')
    minorname="${majorname%_*}_${minor}"
    minorid=$(funFogApi GET /image '{"name": "'${minorname}'"}' | jq -r '.images[0].id // ""')
    if [ -z "$minorid" ] || [ "$minorid" == "null" ]; then
      funFogApi POST /image/ '{ "imageTypeID": "1", "imagePartitionTypeID": "1", "name": "'${minorname}'", "path": "'${minorname}'", "osID": "50", "format": "0", "magnet": "", "protected": "0", "compress": "6", "isEnabled": "1", "toReplicate": "1", "os": {"id": "50", "name": "Linux", "description": ""}, "imagepartitiontype": {"id": "1", "name": "Everything", "type": "all"}, "imagetype": {"id": "1", "name": "Single Disk - Resizable", "type": "n"}, "imagetypename": "Single Disk - Resizable", "imageparttypename": "Everything", "osname": "Linux", "storagegroupname": "default"}' || true
      minorid=$(funFogApi GET /image '{"name": "'${minorname}'"}' | jq -r '.images[0].id // ""')
    fi
    if [ -z "$minorid" ] || [ "$minorid" == "null" ]; then
      echo "WARNING: could not create image ${minorname}; skipping the minor-named twin"
      continue
    fi
    echo "Capturing $host again as ${minorname} (image $minorid)"
    funFogApi PUT /host/$foghostid '{"imageID": "'${minorid}'"}'
    funFogApi POST /host/$foghostid/task '{"taskTypeID": "'${fogcaptureid}'"}'
    funReboot $host
    twincaptures=true
  done 3< $statefile
  if [ "$twincaptures" == "true" ]; then
    funWaitForCaptureTasks
  fi
  # NOTE: the queue deliberately stays paused here; the verify phase unpauses
  # it once the new images have been proven to boot.
}

# Wait until FOG reports no active Capture tasks.  Uses $fogcaptureid.
funWaitForCaptureTasks () {
  local capturetasks currentretries=0
  capturetasks=$(funFogApi GET /task/active '{"typeID": "'${fogcaptureid}'"}' | jq -r '.count // 0')
  while [ "${capturetasks:-1}" -gt 0 ]; do
    echo "$(date) -- $capturetasks FOG capture tasks still queued.  Sleeping 10sec"
    sleep 10
    capturetasks=$(funFogApi GET /task/active '{"typeID": "'${fogcaptureid}'"}' | jq -r '.count // 0')
    ((++currentretries))
    # Retry for 30min
    funRetry $currentretries 180
  done
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
      deployedat=$(funHostDeployedAt $targetid)
      funFogApi PUT /host/$targetid '{"imageID": "'${typeimages[$i]}'"}'
      funFogApi POST /host/$targetid/task '{"taskTypeID": "'${fogdeployid}'"}'
      funReboot $target
      echo "$target ${typedistros[$i]} $targetid ${deployedat:-none}" >> $verifyfile
    done
  done

  # Wait for the verify deploys to finish, then for first-boot config
  verifyids=$(awk '{print $3}' $verifyfile | jq -R . | jq -sc .)
  funWaitForOurTasks "$verifyids" 120

  while read -u3 -r target distro targetid deployedat; do
    # The task is gone; make sure it actually deployed (see phase_deploy)
    if [ "$(funHostDeployedAt $targetid)" == "$deployedat" ]; then
      echo "ERROR: FOG never recorded a successful deploy of the new $distro image on $target.  Queue stays paused."
      exit 1
    fi
    funWaitForHost $target 60
    # The deployed host must come up as itself, not as the capture host
    actualhostname=$(ssh $sshopts ubuntu@${target}.front.sepia.ceph.com "hostname -s")
    if [ "$actualhostname" != "$target" ]; then
      echo "ERROR: $target booted the new $distro image with hostname '$actualhostname'.  Queue stays paused."
      exit 1
    fi
    # ... and running the distro the image is named after.  Build #4
    # (2026-08-19) captured and "verified" an Ubuntu install as rocky_10
    # because this only checked the hostname.
    funCheckHostOs $target $distro || { echo "ERROR: the new $distro image is not $distro.  Queue stays paused."; exit 1; }
    echo "Verified: $distro image boots and configures correctly on $target"
  done 3< $verifyfile

  # Release any extra hosts we claimed just for verification
  funRelease $extrahosts

  # The new images are good; the queue can deploy them again
  funPauseQueue 0
  rm -f $WORKSPACE/captures-started
}

phase_unlock () {
  funActivateVenv

  if [ "$use_teuthologylock" = true ]; then
    # Unlock all machines after all capture images are finished
    funRelease $(funAllHosts)
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
      funPauseQueue 7200
    else
      funPauseQueue 0
    fi
  fi

  if [ "$use_teuthologylock" = true ]; then
    # Unlock all machines
    funRelease $allhosts
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
