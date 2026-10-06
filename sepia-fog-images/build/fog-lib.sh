#!/bin/bash
# fog-lib.sh: OS-agnostic plumbing shared by the sepia FOG image jobs --
# FOG API access, IPMI power control, dnsmasq PXE repointing, MAAS
# machine-state handling, and teuthology lock/queue management.  Everything
# distro-specific (image naming, ssh users, fsck tooling, os-release checks)
# stays in the per-job script that sources this file.
#
# Contract with the sourcing script:
#   - Jenkins provides WORKSPACE, BUILD_NUMBER, and the credentials()
#     variables mapped below (SEPIA_IPMI_PSW, FOG_USR/_PSW, MAAS_API_KEY).
#   - funPauseQueue reads $PAUSEQUEUE and $pausetypes from the caller.
#   - funWaitForCaptureTasks reads $fogcaptureid from the caller.
#   - The task-wait helpers re-reboot hosts whose task is never picked up
#     (see funNudgeUncheckedTasks), so the sourcing script must define
#     funReboot <host>.
# The caller is expected to run under set -ex; the set +x/set -x dances in
# here assume xtrace is on.

# Lab topology.  Adjust here if services move.
fogserver="soko03.front.sepia.ceph.com"
dnsmasqserver="soko01.front.sepia.ceph.com"
dnsmasquser="cm"  # soko01 has no ubuntu user
dnsmasqconf="/etc/dnsmasq.d/pok/front.conf"
maasurl="http://soko02.front.sepia.ceph.com:5240/MAAS/"
maasprofile="jenkins"

# Testnode host keys change constantly (reimages, rescue environments)
sshopts="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10"

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

# Thin wrapper around the FOG API.  Usage: funFogApi <METHOD> </path> [data]
# (xtrace is suppressed inside so the API tokens stay out of the console log)
#
# Responses are scrubbed of per-host secrets before they can reach the
# (public) console log: FOG host records carry the host's client auth token
# and AD/product-key fields, and the PUT /host responses in the deploy,
# capture, and verify phases land on stdout unconsumed.  walk() is defined
# inline for jq-1.5 compatibility; a non-JSON response passes through as-is.
# No caller reads any of the deleted fields.
funFogApi () {
  { set +x; } 2>/dev/null
  local rc out
  out=$(curl -f -s -k \
    -H "fog-api-token: ${FOG_API_TOKEN}" \
    -H "fog-user-token: ${FOG_USER_TOKEN}" \
    -X "$1" "http://${fogserver}/fog${2}" ${3:+-d "$3"})
  rc=$?
  printf '%s' "$out" | jq '
    def walk(f): . as $in
      | if type == "object" then
          reduce keys_unsorted[] as $key ({}; . + {($key): ($in[$key] | walk(f))}) | f
        elif type == "array" then map(walk(f)) | f
        else f end;
    walk(if type == "object"
         then del(.token, .sec_tok, .ADPass, .ADPassLegacy, .productKey)
         else . end)' 2>/dev/null || printf '%s\n' "$out"
  set -x
  return $rc
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
# Fails loudly if the host has no dhcp-host entry at all (a silent sed no-op
# here would leave the node PXE-booting from the wrong server).
funSetPxe () {
  if ! ssh $sshopts ${dnsmasquser}@${dnsmasqserver} "sudo sed -i -E 's/^dhcp-host=set:(fog|maas),(.*[,=]${1}\.front\.sepia\.ceph\.com)\$/dhcp-host=set:${2},\2/' $dnsmasqconf && grep -Eq '^dhcp-host=set:${2},.*[,=]${1}\.front\.sepia\.ceph\.com\$' $dnsmasqconf && sudo systemctl restart dnsmasq"; then
    echo "ERROR: could not point ${1}'s PXE entry at ${2} -- does $1 have a dhcp-host line in $dnsmasqconf on ${dnsmasqserver}?"
    return 1
  fi
}

funActivateVenv () {
  cd $WORKSPACE
  source $WORKSPACE/teuthology/virtualenv/bin/activate 2>/dev/null || \
    source $WORKSPACE/teuthology/.venv/bin/activate
}

# A host whose FOG task is never picked up needs another reboot: a warm
# IPMI power cycle on the newer trial sleds intermittently skips PXE (the
# E810 link is not up in time for the PXE DHCP window) and the host boots
# its local OS, leaving the task queued with checkInTime unset forever.
# Build #40 (2026-09-27) lost 2 of 4 captures to this and #41 nearly
# followed; a clean reboot PXE'd reliably both times it was tried.  So:
# count the polls each of our hosts spends with a queued (stateID 1),
# never-checked-in task, and after $3 such polls funReboot it again, at
# most twice per host per wait.  A task that has checked in (imaging, or
# merely slow) is never touched.  The counters are globals reset by the
# wait helpers below.
# Usage: funNudgeUncheckedTasks <active-tasks-json> <hostids-json> <gracepolls>
declare -A fognudgeseen fognudgecount
funNudgeUncheckedTasks () {
  local host
  while read -r host; do
    [ -n "$host" ] || continue
    fognudgeseen[$host]=$(( ${fognudgeseen[$host]:-0} + 1 ))
    if [ "${fognudgeseen[$host]}" -ge "$3" ] && [ "${fognudgecount[$host]:-0}" -lt 2 ]; then
      fognudgecount[$host]=$(( ${fognudgecount[$host]:-0} + 1 ))
      fognudgeseen[$host]=0
      echo "$(date) -- ${host}'s FOG task was never picked up (host likely fell through PXE to local boot); rebooting it again (nudge ${fognudgecount[$host]}/2)"
      funReboot $host || true
    fi
  done < <(echo "$1" | jq -r --argjson ids "$2" '
    (.tasks // [])[]
    | select((.hostID|tostring) as $h | $ids | index($h))
    | select((.stateID|tostring) == "1")
    | select(((.checkInTime // "") | startswith("0000")) or (.checkInTime // "") == "")
    | .host.name // empty')
}

# Wait until none of the given FOG host IDs have active tasks, re-rebooting
# hosts whose task is never picked up (10 polls ~= 5min; see
# funNudgeUncheckedTasks).  Usage: funWaitForOurTasks '["1","2"]' [maxretries]
funWaitForOurTasks () {
  local currentretries=0 activetasks resp
  fognudgeseen=()
  fognudgecount=()
  while true; do
    resp=$(funFogApi GET /task/active)
    activetasks=$(echo "$resp" | jq -r --argjson ids "$1" '[(.tasks // [])[] | select((.hostID|tostring) as $h | $ids | index($h))] | length')
    if [ "${activetasks:-1}" == "0" ]; then
      break
    fi
    funNudgeUncheckedTasks "$resp" "$1" 10
    echo "$(date) -- $activetasks FOG tasks for our hosts still active.  Sleeping 30sec"
    sleep 30
    ((++currentretries))
    funRetry $currentretries ${2:-120}
  done
}

# MAAS machine handling.  When an OS has no captured FOG image yet, MAAS
# (soko02) installs it from scratch so there is something to update and
# capture (STARTWITHMAAS); MAAS rescue mode is also one of the fsck paths.
# These helpers cover the OS-agnostic parts: log in to MAAS, get a machine
# into a deployable state, and wait for a deploy to finish.  Mapping a
# distro onto a MAAS boot resource and starting the deploy stay in the
# job script (funMaasImage/funMaasSeedStart).

# Log in to the MAAS CLI once per script invocation.  set +x keeps the API
# key out of the console log.
maasloggedin=false
funMaasLogin () {
  [ "$maasloggedin" == "true" ] && return 0
  if ! command -v maas >/dev/null 2>&1; then
    echo "ERROR: the maas CLI is required on this node (apt install maas-cli)"
    exit 1
  fi
  { set +x; } 2>/dev/null
  maas login $maasprofile $maasurl "$MAAS_API_KEY"
  set -x
  maasloggedin=true
}

# Usage: funMaasSystemId <host>.  Prints the MAAS system_id or nothing.
funMaasSystemId () {
  maas $maasprofile machines read hostname=$1 | jq -r '.[0].system_id // ""'
}

# Get a MAAS machine to the Ready state so it can be deployed: commission a
# never-used (New) machine -- PXE already points at maas by the time this
# runs, so the ephemeral commissioning boot works -- exit rescue mode,
# release a stale Deployed/Allocated record, mark a Broken one fixed.
# Usage: funMaasEnsureReady <systemid> <host>
funMaasEnsureReady () {
  local systemid=$1 host=$2 status currentretries=0 commissionattempts=0
  while true; do
    status=$(maas $maasprofile machine read $systemid | jq -r '.status_name')
    case "$status" in
      Ready)
        return 0 ;;
      New|"Failed commissioning")
        # "Failed commissioning" is usually a stale record or a flubbed PXE
        # boot from an earlier attempt, not a verdict on the hardware --
        # re-commission a bounded number of times before declaring the
        # machine actually sick.
        if [ $commissionattempts -ge 2 ]; then
          echo "ERROR: $host is still in MAAS state '$status' after $commissionattempts commissioning attempts; fix it in MAAS first"
          exit 1
        fi
        ((++commissionattempts))
        echo "$host is in MAAS state '$status'; commissioning it now (attempt $commissionattempts of 2)"
        maas $maasprofile machine commission $systemid >/dev/null || true ;;
      "Rescue mode"|"Entering rescue mode")
        maas $maasprofile machine exit-rescue-mode $systemid >/dev/null || true ;;
      Deployed|Deploying|Allocated|"Failed deployment")
        maas $maasprofile machine release $systemid >/dev/null || true ;;
      Broken)
        maas $maasprofile machine mark-fixed $systemid >/dev/null || true ;;
      "Failed testing")
        # Old testnode drives routinely trip smartctl-validate on SMART
        # attribute warnings (gibba015, build #16) while still working fine
        # as testnodes -- and a genuinely dead disk still fails the deploy,
        # fsck, or capture.  Override and continue, loudly.
        echo "WARNING: $host failed MAAS hardware testing; overriding and continuing (a truly bad disk will still fail the deploy)"
        maas $maasprofile machine override-failed-testing $systemid >/dev/null || true ;;
      *)
        # Transient (Commissioning, Releasing, Exiting rescue mode, ...):
        # just wait
        : ;;
    esac
    echo "$(date) -- $host is in MAAS state '$status', waiting for Ready.  Sleeping 20sec"
    sleep 20
    ((++currentretries))
    # Retry for 50min (each commissioning attempt takes a full PXE boot,
    # and we allow a re-commission after "Failed commissioning")
    funRetry $currentretries 150
  done
}

# The OS belongs on the spinning disk: testnode NVMe drives are test
# payload, and BIOS-era boxes cannot boot from NVMe at all -- MAAS
# defaulting the install onto the NVMe left gibba014 unbootable (build
# #12).  Point MAAS's boot disk at the smallest rotary disk and rebuild
# the flat storage layout on it (same flow as dgalloway@soko02's
# set-disk.sh, which handles bulk/one-off fixes); machines with no rotary
# disk keep MAAS's default.  Commissioning re-detects storage and resets
# the boot disk, so this must run after commissioning, while Ready.
# Usage: funMaasEnsureBootDisk <systemid> <host>
funMaasEnsureBootDisk () {
  local systemid=$1 host=$2 bds want wantname current out
  bds=$(maas $maasprofile block-devices read $systemid)
  want=$(echo "$bds" | jq -r '[.[] | select(.type == "physical") | select((.tags // []) | index("rotary"))] | sort_by(.size, .name) | .[0].id // ""')
  wantname=$(echo "$bds" | jq -r '[.[] | select(.type == "physical") | select((.tags // []) | index("rotary"))] | sort_by(.size, .name) | .[0].name // ""')
  if [ -z "$want" ]; then
    # No rotary disk (e.g. trial: two big payload NVMes + one small boot
    # NVMe): use the smallest physical disk so the test payload stays
    # clean.  MAAS's default put the OS on a 1920GB payload NVMe and the
    # disk-matching ansible then found only one free ~1700GB disk (#29).
    want=$(echo "$bds" | jq -r '[.[] | select(.type == "physical")] | sort_by(.size, .name) | .[0].id // ""')
    wantname=$(echo "$bds" | jq -r '[.[] | select(.type == "physical")] | sort_by(.size, .name) | .[0].name // ""')
    echo "$host has no rotary disk; using its smallest disk (${wantname}) for the OS"
  fi
  if [ -z "$want" ]; then
    echo "ERROR: $host has no physical disks in MAAS"
    exit 1
  fi
  current=$(maas $maasprofile machine read $systemid | jq -r '.boot_disk.name // ""')
  if [ "$current" == "$wantname" ]; then
    return 0
  fi
  echo "Setting ${host}'s boot disk to ${wantname} so the OS lands on the HDD, not the NVMe"
  out=$(maas $maasprofile block-device set-boot-disk $systemid $want 2>&1) || {
    echo "$out"
    echo "ERROR: could not set ${host}'s boot disk to ${wantname}"
    exit 1
  }
  # Blank first so the flat layout is rebuilt from scratch on the new disk
  maas $maasprofile machine set-storage-layout $systemid storage_layout=blank >/dev/null
  out=$(maas $maasprofile machine set-storage-layout $systemid storage_layout=flat 2>&1) || {
    echo "$out"
    echo "ERROR: could not rebuild ${host}'s storage layout on ${wantname}"
    exit 1
  }
}

# MAAS refuses to deploy a machine whose boot interface has no address
# configuration -- a fresh commission comes up with a bare link_up link and
# deploy fails with "Node must be configured to use a network" (build #11).
# Configure the boot interface for DHCP: dnsmasq owns DHCP here with
# MAC-reserved IPs, so the deployed OS keeps the same identity a FOG image
# would have.  Usage: funMaasEnsureNetwork <systemid> <host>
funMaasEnsureNetwork () {
  local systemid=$1 host=$2 bootif ifjson subnetid vlanid linkid out
  bootif=$(maas $maasprofile machine read $systemid | jq -r '.boot_interface.id // ""')
  if [ -z "$bootif" ]; then
    echo "ERROR: $host has no boot interface in MAAS"
    exit 1
  fi
  ifjson=$(maas $maasprofile interface read $systemid $bootif)
  if echo "$ifjson" | jq -e '[(.links // [])[] | select(.mode == "dhcp")] | length > 0' >/dev/null; then
    # Already DHCP
    return 0
  fi
  subnetid=$(echo "$ifjson" | jq -r '(.links // [])[0].subnet.id // ""')
  # Drop any auto/static links first: MAAS would otherwise deploy the OS
  # with a static address of its own choosing, while DNS and this job
  # address the host by its dnsmasq MAC-reservation (build #24: trial001
  # deployed at a MAAS-picked .192.89 while DNS said .193.1).  A fresh
  # commission leaves an "auto" link, so this is the common case.
  for linkid in $(echo "$ifjson" | jq -r '(.links // [])[] | select(.mode != "link_up") | .id'); do
    echo "Removing ${host}'s non-DHCP boot interface link $linkid"
    maas $maasprofile interface unlink-subnet $systemid $bootif id=$linkid >/dev/null
  done
  if [ -z "$subnetid" ]; then
    # No subnet on the link_up link either; find one on the interface's VLAN
    vlanid=$(echo "$ifjson" | jq -r '.vlan.id // ""')
    subnetid=$(maas $maasprofile subnets read | jq -r --arg v "$vlanid" '[.[] | select((.vlan.id|tostring) == $v)][0].id // ""')
  fi
  if [ -z "$subnetid" ]; then
    echo "ERROR: cannot find a MAAS subnet for ${host}'s boot interface"
    exit 1
  fi
  echo "Configuring ${host}'s boot interface for DHCP (subnet $subnetid)"
  out=$(maas $maasprofile interface link-subnet $systemid $bootif mode=DHCP subnet=$subnetid 2>&1) || {
    echo "$out"
    echo "ERROR: could not configure ${host}'s boot interface for DHCP"
    exit 1
  }
}

# Wait until MAAS reports <host> Deployed.  Usage: funMaasWaitDeployed <host>
funMaasWaitDeployed () {
  local host=$1 systemid status currentretries=0
  funMaasLogin
  systemid=$(funMaasSystemId $host)
  while true; do
    status=$(maas $maasprofile machine read $systemid | jq -r '.status_name')
    if [ "$status" == "Deployed" ]; then
      return 0
    fi
    if [ "$status" == "Failed deployment" ]; then
      echo "ERROR: MAAS deploy of $host failed; see its installation log in MAAS"
      exit 1
    fi
    echo "$(date) -- $host MAAS status: '$status' (waiting for Deployed).  Sleeping 30sec"
    sleep 30
    ((++currentretries))
    # Retry for 45min (a from-scratch install is much slower than a FOG deploy)
    funRetry $currentretries 90
  done
}

# Print the FOG host ID for <host>, registering the host in FOG first if it
# isn't there yet (MAC address comes from MAAS, which is where a host being
# seeded lives anyway).  Diagnostics go to stderr; stdout is only the ID.
# Usage: funEnsureFogHost <host>
funEnsureFogHost () {
  local host=$1 id mac systemid
  id=$(funFogApi GET /host '{"name": "'${host}'"}' | jq -r '.hosts[0].id // ""')
  if [ -n "$id" ] && [ "$id" != "null" ]; then
    echo $id
    return 0
  fi
  echo "Registering $host in FOG at http://${fogserver}/fog" >&2
  funMaasLogin >&2
  systemid=$(funMaasSystemId $host)
  if [ -z "$systemid" ]; then
    echo "ERROR: $host is in neither FOG nor MAAS; register it in one of them first" >&2
    return 1
  fi
  mac=$(maas $maasprofile machine read $systemid | jq -r '.boot_interface.mac_address // ""')
  if [ -z "$mac" ]; then
    echo "ERROR: could not read ${host}'s boot MAC from MAAS" >&2
    return 1
  fi
  funFogApi POST /host/ "$(jq -nc --arg n "$host" --arg m "$mac" '{name: $n, macs: [$m]}')" >&2 || true
  id=$(funFogApi GET /host '{"name": "'${host}'"}' | jq -r '.hosts[0].id // ""')
  if [ -z "$id" ] || [ "$id" == "null" ]; then
    echo "ERROR: could not register $host (MAC $mac) in FOG" >&2
    return 1
  fi
  echo "Registered $host in FOG as host ID $id (MAC $mac)" >&2
  echo $id
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

# FOG's per-host "deployed" timestamp is only bumped when a deploy task
# completes successfully, so it tells a real deploy apart from a task that
# was cancelled or died in FOS (after which the node just boots whatever
# was on its disk).  Usage: funHostDeployedAt <foghostid>
funHostDeployedAt () {
  funFogApi GET /host/$1 | jq -r '.deployed // ""'
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
#
# Reimaged nodes regenerate their ssh host keys (prep-fog-capture's
# regen-ssh-hostkeys.service), but teuthology's paramiko auto-adds keys to
# the agent's ~/.ssh/known_hosts at lock time, so the unlock's stop_node
# reconnect then spends ~10 minutes failing on BadHostKeyException before
# giving up (build #15).  Forget any recorded keys first so the unlock can
# actually reach the node and power it down.
funRelease () {
  if [ $# -eq 0 ]; then
    return 0
  fi
  local host short
  for host in "$@"; do
    short=${host%%.*}
    ssh-keygen -R ${short}.front.sepia.ceph.com >/dev/null 2>&1 || true
    ssh-keygen -R ${short} >/dev/null 2>&1 || true
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

# Wait until FOG reports no active Capture tasks.  Uses $fogcaptureid.
# With a JSON array of our FOG host IDs as $1, hosts whose capture task is
# never picked up are re-rebooted (30 polls ~= 5min; see
# funNudgeUncheckedTasks); the exit condition is unchanged.
# Usage: funWaitForCaptureTasks ['["1","2"]']
funWaitForCaptureTasks () {
  local capturetasks currentretries=0 resp
  fognudgeseen=()
  fognudgecount=()
  resp=$(funFogApi GET /task/active '{"typeID": "'${fogcaptureid}'"}')
  capturetasks=$(echo "$resp" | jq -r '.count // 0')
  while [ "${capturetasks:-1}" -gt 0 ]; do
    if [ -n "${1:-}" ]; then
      funNudgeUncheckedTasks "$resp" "$1" 30
    fi
    echo "$(date) -- $capturetasks FOG capture tasks still queued.  Sleeping 10sec"
    sleep 10
    resp=$(funFogApi GET /task/active '{"typeID": "'${fogcaptureid}'"}')
    capturetasks=$(echo "$resp" | jq -r '.count // 0')
    ((++currentretries))
    # Retry for 30min
    funRetry $currentretries 180
  done
}
