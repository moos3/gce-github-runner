#!/usr/bin/env bash

ACTION_DIR="$( cd $( dirname "${BASH_SOURCE[0]}" ) >/dev/null 2>&1 && pwd )"

function usage {
  echo "Usage: ${0} --command=[start|stop] <arguments>"
}

function safety_on {
  set -o errexit -o pipefail -o noclobber -o nounset
}

function safety_off {
  set +o errexit +o pipefail +o noclobber +o nounset
}

command=
token=
project_id=
service_account_key=
runner_ver=
machine_zone=
machine_type=
boot_disk_type=
disk_size=
runner_service_account=
image_project=
image=
image_family=
network=
scopes=
shutdown_timeout=
subnet=
spot=
ephemeral=
no_external_address=
actions_preinstalled=
maintenance_policy_terminate=
instance_termination_action=
arm=
accelerator=
max_run_duration=
org_runner=
vm_id_suffix=
preemptible=

for arg in "$@"
do
    case $arg in
        --command=*)
        command="${arg#*=}"
        shift
        ;;
        --token=*)
        token="${arg#*=}"
        shift
        ;;
        --project_id=*)
        project_id="${arg#*=}"
        shift
        ;;
        --service_account_key=*)
        service_account_key="${arg#*=}"
        service_account_key=$(echo "$service_account_key" | base64 --decode)
        shift
        ;;
        --runner_ver=*)
        runner_ver="${arg#*=}"
        shift
        ;;
        --machine_zone=*)
        machine_zone="${arg#*=}"
        shift
        ;;
        --machine_type=*)
        machine_type="${arg#*=}"
        shift
        ;;
        --network=*)
        network="${arg#*=}"
        shift
        ;;
        --subnet=*)
        subnet="${arg#*=}"
        shift
        ;;
        --accelerator=*)
        accelerator="${arg#*=}"
        shift
        ;;
        --disk_size=*)
        disk_size="${arg#*=}"
        shift
        ;;
        --scopes=*)
        scopes="${arg#*=}"
        shift
        ;;
        --shutdown_timeout=*)
        shutdown_timeout="${arg#*=}"
        shift
        ;;
        --runner_service_account=*)
        runner_service_account="${arg#*=}"
        shift
        ;;
        --image_project=*)
        image_project="${arg#*=}"
        shift
        ;;
        --image=*)
        image="${arg#*=}"
        shift
        ;;
        --image_family=*)
        image_family="${arg#*=}"
        shift
        ;;
        --boot_disk_type=*)
        boot_disk_type="${arg#*=}"
        shift
        ;;
        --spot=*)
        spot="${arg#*=}"
        shift
        ;;
        --ephemeral=*)
        ephemeral="${arg#*=}"
        shift
        ;;
        --no_external_address=*)
        no_external_address="${arg#*=}"
        shift
        ;;
        --actions_preinstalled=*)
        actions_preinstalled="${arg#*=}"
        shift
        ;;
        --maintenance_policy_terminate=*)
        maintenance_policy_terminate="${arg#*=}"
        shift
        ;;
        --instance_termination_action=*)
        instance_termination_action="${arg#*=}"
        shift
        ;;
        --arm=*)
        arm="${arg#*=}"
        shift
        ;;
        --max_run_duration=*)
        max_run_duration="${arg#*=}"
        shift
        ;;
        --org_runner=*)
        org_runner="${arg#*=}"
        shift
        ;;
        --vm_id_suffix=*)
        vm_id_suffix="${arg#*=}"
        shift
        ;;
        --preemptible=*)
        preemptible="${arg#*=}"
        shift
        ;;
        *)
        option="${arg%%=*}"
        value="${arg#*=}"
        echo "Error: Unsupported flag $option with value $value" >&2
        #Sexit 1
        ;;
    esac
done
  
function gcloud_auth {
  # NOTE: when --project is specified, it updates the config
  echo "service_account_key: ${service_account_key}"
  echo ${service_account_key} | gcloud --project  ${project_id} --quiet auth activate-service-account --key-file - &>/dev/null
  echo "✅ Successfully configured gcloud."
}

function start_vm {
  echo "Starting GCE VM ..."
  if [[ -z "${service_account_key}" ]] || [[ -z "${project_id}" ]]; then
    echo "Won't authenticate gcloud. If you wish to authenticate gcloud provide both service_account_key and project_id."
  else
    echo "Will authenticate gcloud."
    gcloud_auth
  fi

  registration_token_url=$([[ "${org_runner}" == "true" ]] && \
    echo "https://api.github.com/orgs/${GITHUB_REPOSITORY_OWNER}/actions/runners/registration-token" || \
    echo "https://api.github.com/repos/${GITHUB_REPOSITORY}/actions/runners/registration-token")

  RUNNER_TOKEN=$(curl -S -s -XPOST \
      -H "authorization: Bearer ${token}" \
      ${registration_token_url} |\
      jq -r .token)
  echo "✅ Successfully got the GitHub Runner registration token"

  VM_ID="gce-gh-runner-${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT}${vm_id_suffix}"
  service_account_flag=$([[ -z "${runner_service_account}" ]] || echo "--service-account=${runner_service_account}")
  image_project_flag=$([[ -z "${image_project}" ]] || echo "--image-project=${image_project}")
  image_flag=$([[ -z "${image}" ]] || echo "--image=${image}")
  image_family_flag=$([[ -z "${image_family}" ]] || echo "--image-family=${image_family}")
  disk_size_flag=$([[ -z "${disk_size}" ]] || echo "--boot-disk-size=${disk_size}")
  boot_disk_type_flag=$([[ -z "${boot_disk_type}" ]] || echo "--boot-disk-type=${boot_disk_type}")
  spot_flag=$([[ "${spot}" == "true" ]] && echo "--provisioning-model=SPOT --instance-termination-action=${instance_termination_action}" || echo "")
  ephemeral_flag=$([[ "${ephemeral}" == "true" ]] && echo "--ephemeral" || echo "")
  no_external_address_flag=$([[ "${no_external_address}" == "true" ]] && echo "--no-address" || echo "")
  network_flag=$([[ ! -z "${network}"  ]] && echo "--network=${network}" || echo "")
  subnet_flag=$([[ ! -z "${subnet}"  ]] && echo "--subnet=${subnet}" || echo "")
  accelerator=$([[ ! -z "${accelerator}"  ]] && echo "--accelerator=${accelerator} --maintenance-policy=TERMINATE" || echo "")
  max_run_duration_flag=$([[ ! -z "${max_run_duration}"  ]] && echo "--max-run-duration=${max_run_duration} --instance-termination-action=${instance_termination_action}" || echo "")
  maintenance_policy_flag=$([[ -z "${maintenance_policy_terminate}"  ]] || echo "--maintenance-policy=TERMINATE" )
  runner_registration_url=$([[ "${org_runner}" == "true" ]] && echo "https://github.com/${GITHUB_REPOSITORY_OWNER}" || echo "https://github.com/${GITHUB_REPOSITORY}")

  echo "after check Image Family: ${image_family_flag}"
  echo "after check Image Family: ${image_family}"
  
  echo "The new GCE VM will be ${VM_ID}"

  cat <<-EOT > /tmp/shutdown_script.sh
	#!/bin/bash
	preempted=\$(curl -Ss http://metadata.google.internal/computeMetadata/v1/instance/preempted -H 'Metadata-Flavor: Google')
	if [[ \$preempted = 'TRUE' ]]; then
	pr_numbers=\$(curl -sSL \\
	  -H "Accept: application/vnd.github+json" \\
	  -H "Authorization: Bearer ${token}" \\
	  https://api.github.com/repos/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID} | jq -r '.pull_requests[] | .number'
	)
	pr_numbers=(\${pr_numbers})
	for pr_number in \${pr_numbers[@]}; do
	  curl -sSL \\
	    -X POST \\
	    -H "Accept: application/vnd.github+json" \\
	    -H "Authorization: Bearer ${token}" \\
	    -d '{"body": "### Github runner instance in GCE was preempted\nPlease [re-run the jobs](https://github.com/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID})."}' \\
	    https://api.github.com/repos/${GITHUB_REPOSITORY}/issues/\${pr_number}/comments
	done
	[[ -x /opt/deeplearning/bin/shutdown_script.sh ]] && /opt/deeplearning/bin/shutdown_script.sh
	CLOUDSDK_CONFIG=/tmp  gcloud --quiet compute instances delete ${VM_ID} --zone=${machine_zone} || true
	fi
	EOT
  shutdown_script="$(cat /tmp/shutdown_script.sh)"

  startup_script="
	# Install NVIDIA driver if exists
	[[ -x /opt/deeplearning/install-driver.sh ]] && /opt/deeplearning/install-driver.sh

	cat <<-'EOT' > /tmp/shutdown_script.sh
	${shutdown_script}
	EOT
	chmod +x /tmp/shutdown_script.sh
	gcloud --quiet compute instances add-metadata $VM_ID --zone=${machine_zone} --metadata-from-file=shutdown-script=/tmp/shutdown_script.sh

	# Create a systemd service in charge of shutting down the machine once the workflow has finished
	cat <<-EOF > /etc/systemd/system/shutdown.sh
	#!/bin/sh
	sleep ${shutdown_timeout}
	CLOUDSDK_CONFIG=/tmp gcloud compute instances delete $VM_ID --zone=$machine_zone --quiet
	EOF

	cat <<-EOF > /etc/systemd/system/shutdown.service
	[Unit]
	Description=Shutdown service
	[Service]
	ExecStart=/etc/systemd/system/shutdown.sh
	[Install]
	WantedBy=multi-user.target
	EOF

	chmod +x /etc/systemd/system/shutdown.sh
	systemctl daemon-reload
	systemctl enable shutdown.service

	cat <<-EOF > /usr/bin/gce_runner_shutdown.sh
	#!/bin/sh
	echo \"✅ Self deleting $VM_ID in ${machine_zone} in ${shutdown_timeout} seconds ...\"
	# We tear down the machine by starting the systemd service that was registered by the startup script
	systemctl start shutdown.service
	EOF

	# See: https://docs.github.com/en/actions/hosting-your-own-runners/managing-self-hosted-runners/running-scripts-before-or-after-a-job
	echo "ACTIONS_RUNNER_HOOK_JOB_COMPLETED=/usr/bin/gce_runner_shutdown.sh" >.env
	gcloud compute instances add-labels ${VM_ID} --zone=${machine_zone} --labels=gh_ready=0 && \\
	RUNNER_ALLOW_RUNASROOT=1 ./config.sh --url ${runner_registration_url} --token ${RUNNER_TOKEN} --labels ${VM_ID} --unattended ${ephemeral_flag} --disableupdate && \\
	./svc.sh install && \\
	./svc.sh start && \\
	gcloud compute instances add-labels ${VM_ID} --zone=${machine_zone} --labels=gh_ready=1
  "

  if $actions_preinstalled ; then
    echo "✅ Startup script won't install GitHub Actions (pre-installed)"
    startup_script="#!/bin/bash
    cd /actions-runner
    $startup_script"
  else
    if [[ "$runner_ver" = "latest" ]]; then
      latest_ver=$(curl -sL https://api.github.com/repos/actions/runner/releases/latest | jq -r '.tag_name' | sed -e 's/^v//')
      runner_ver="$latest_ver"
      echo "✅ runner_ver=latest is specified. v$latest_ver is detected as the latest version."
    fi
    echo "✅ Startup script will install GitHub Actions v$runner_ver"
    if $arm ; then
      startup_script="#!/bin/bash
      mkdir /actions-runner
      cd /actions-runner
      curl -o actions-runner-linux-arm64-${runner_ver}.tar.gz -L https://github.com/actions/runner/releases/download/v${runner_ver}/actions-runner-linux-arm64-${runner_ver}.tar.gz
      tar xzf ./actions-runner-linux-arm64-${runner_ver}.tar.gz
      ./bin/installdependencies.sh && \\
      $startup_script"
    else
      startup_script="#!/bin/bash
      mkdir /actions-runner
      cd /actions-runner
      curl -o actions-runner-linux-x64-${runner_ver}.tar.gz -L https://github.com/actions/runner/releases/download/v${runner_ver}/actions-runner-linux-x64-${runner_ver}.tar.gz
      tar xzf ./actions-runner-linux-x64-${runner_ver}.tar.gz
      ./bin/installdependencies.sh && \\
      $startup_script"
    fi
  fi
  
  # GCE VM label values requirements:
  # - can contain only lowercase letters, numeric characters, underscores, and dashes
  # - have a maximum length of 63 characters
  # ref: https://cloud.google.com/compute/docs/labeling-resources#requirements
  #
  # Github's requirements:
  # - username/organization name
  #   - Max length: 39 characters
  #   - All characters must be either a hyphen (-) or alphanumeric
  # - repository name
  #   - Max length: 100 code points
  #   - All code points must be either a hyphen (-), an underscore (_), a period (.), 
  #     or an ASCII alphanumeric code point
  # ref: https://github.com/dead-claudia/github-limits
  function truncate_to_label {
    local in="${1}"
    in="${in:0:63}"                              # ensure max length
    in="${in//./_}"                              # replace '.' with '_'
    in=$(tr '[:upper:]' '[:lower:]' <<< "${in}") # convert to lower
    echo -n "${in}"
  }
  gh_repo_owner="$(truncate_to_label "${GITHUB_REPOSITORY_OWNER}")"
  gh_repo="$(truncate_to_label "${GITHUB_REPOSITORY##*/}")"
  gh_run_id="${GITHUB_RUN_ID}"

  echo gcloud compute instances create ${VM_ID} \
    --zone=${machine_zone} \
    ${disk_size_flag} \
    ${boot_disk_type_flag} \
    --machine-type=${machine_type} \
    --scopes=${scopes} \
    ${service_account_flag} \
    ${image_project_flag} \
    ${image_flag} \
    ${image_family_flag} \
    ${spot_flag} \
    ${no_external_address_flag} \
    ${subnet_flag} \
    ${accelerator} \
    ${max_run_duration_flag} \
    ${maintenance_policy_flag} \
    --labels=gh_ready=0,gh_repo_owner="${gh_repo_owner}",gh_repo="${gh_repo}",gh_run_id="${gh_run_id}" \
    --metadata-from-file=shutdown-script=/tmp/shutdown_script.sh \
    --metadata=startup-script="$startup_script"


  gcloud compute instances create ${VM_ID} \
    --zone=${machine_zone} \
    ${disk_size_flag} \
    ${boot_disk_type_flag} \
    --machine-type=${machine_type} \
    --scopes=${scopes} \
    ${service_account_flag} \
    ${image_project_flag} \
    ${image_flag} \
    ${image_family_flag} \
    ${spot_flag} \
    ${no_external_address_flag} \
    ${subnet_flag} \
    ${accelerator} \
    ${max_run_duration_flag} \
    ${maintenance_policy_flag} \
    --labels=gh_ready=0,gh_repo_owner="${gh_repo_owner}",gh_repo="${gh_repo}",gh_run_id="${gh_run_id}" \
    --metadata-from-file=shutdown-script=/tmp/shutdown_script.sh \
    --metadata=startup-script="$startup_script" \
    && echo "label=${VM_ID}" >> $GITHUB_OUTPUT

  safety_off
  while (( i++ < 60 )); do
    GH_READY=$(gcloud compute instances describe ${VM_ID} --zone=${machine_zone} --format='json(labels)' | jq -r .labels.gh_ready)
    if [[ $GH_READY == 1 ]]; then
      break
    fi
    echo "${VM_ID} not ready yet, waiting 5 secs ..."
    sleep 5
  done
  if [[ $GH_READY == 1 ]]; then
    echo "✅ ${VM_ID} ready ..."
  else
    echo "Waited 5 minutes for ${VM_ID}, without luck, deleting ${VM_ID} ..."
    gcloud --quiet compute instances delete ${VM_ID} --zone=${machine_zone}
    exit 1
  fi
}

safety_on
case "$command" in
  start)
    start_vm
    ;;
  *)
    echo "Invalid command: \`${command}\`, valid values: start" >&2
    usage
    exit 1
    ;;
esac
