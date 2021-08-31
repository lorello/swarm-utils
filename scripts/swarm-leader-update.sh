#!/usr/bin/env bash
#
# Set EC2 tag Name to the current HOSTNAME of the instance
#
# Required policy:
#
# {
#    "Version": "2012-10-17",
#    "Statement": [
#        {
#            "Sid": "VisualEditor0",
#            "Effect": "Allow",
#            "Action": [
#                "ec2:DeleteTags",
#                "ec2:DescribeTags",
#                "ec2:CreateTags"
#            ],
#            "Resource": "*"
#        }
#    ]
# }
#
# Add this to the IAM Role of the EC2 host and this script will run smoothly!
#

[[ $DEBUG ]] && set -ex


set -Eeuo pipefail
trap cleanup SIGINT SIGTERM ERR EXIT

cleanup() {
  trap - SIGINT SIGTERM ERR EXIT
  echo "Got signal to terminate, now exiting"
  exit 0
}




# AutoScaling Group of swarm managers
asgName=${AUTOSCALING_GROUP_NAME:-swarm-managers}

function logerr {
  msg=${1?"logerr: missing parameter #1 (msg)"}
  echo "[ERROR] $msg" > /dev/stderr
}
function log {
  msg=${1?"logerr: missing parameter #1 (msg)"}
  echo "[INFO] $msg" > /dev/stdout
}

if [[ -z $HOSTNAME ]]; then
  logerr "Cannot procede without a valid HOSTNAME"
  exit 1
fi

#################################################################################################
# Retrieve metadata info of the current node

region=$(http http://169.254.169.254/latest/dynamic/instance-identity/document | jq -c -r .region)
if [[ -z $region ]]; then
  logerr "Cannot get region info from metatags, am I an EC2 instance? Are httpie and jq installed?"
  exit 2
fi

id=$(http http://169.254.169.254/latest/meta-data/instance-id)



#################################################################################################
# find name and ip of the docker swarm leader
leaderName=$(docker node ls|grep Leader | awk '{ print $2 }')
if [[ $? -gt 0 ]]; then
  logerr "Cannot find the name of the leader node, are you running this script in a manager of a swarm cluster?"
  exit 3
fi


# output of docker node ls has '*' to the node you're connected to
# so the name can be 2nd or 3rd position
if [[ $leaderName == '*' ]]; then
  leaderName=$(docker node ls|grep Leader | awk '{ print $3 }')
fi

if [[ $? -gt 0 ]] || [[ -z $leaderName ]]; then
  logerr "Cannot find leader node, is cluster healthy?"
  exit 3
fi

leaderIp=$(docker node inspect ${leaderName} | jq -r '.[].Status.Addr')
if [[ $? -gt 0 ]] || [[ -z $leaderIp ]]; then
  logerr "Cannot find IP address of leader node, is cluster healthy?"
  exit 6
fi


#################################################################################################
# check if current tagged leader is the right one

# get node tagged as leader in EC2
ec2LeaderIp=$(aws ec2 describe-instances --region ${region} --filter Name=tag:Swarm-Leader,Values=true --output=text --query="Reservations[*].Instances[*].PrivateIpAddress")

if [[ $? -gt 0 ]]; then
  logerr "cannot look for leader IP Address describing EC2 instances, check that you have policy ec2:DescribeInstances"
  exit 4
fi

# check IP of the node tagged leader
if [[ $ec2LeaderIp =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
  log "On EC2 node ec2Leader is $ec2LeaderIp"
  if [[ $leaderIp == $ec2LeaderIp ]]; then
    log "Leader node is updated, nothing to do"
    exit 0
  else
    log "Node tagged as Swarl-Leader on EC2 is wrong: node has IP '$ec2LeaderIp' while the leader has IP '$leaderIp'"
  fi
  else
    log "No nodes tagged as Swarm-Leader on EC2"
fi

log "Leader node must be updated"



#################################################################################################
# Remove the tag Swarm-Leader from all instances
# except the node that is currently the leader

# First, find the EC2 Instance ID of the leader, using the name 
# of the instance previously
ec2LeaderId=$(aws ec2 describe-instances --region ${region} --filter Name=private-ip-address,Values=$leaderIp --output=text --query="Reservations[*].Instances[*].InstanceId")

if [[ $? -gt 0 ]] || [[ -z $ec2LeaderId ]]; then
  logerr "Cannot find Instance ID of the leader, looking for EC2 instance with IP '$leaderIp'"
  exit 7
fi


for instance in $(aws ec2 describe-instances --region ${region} --filter Name=tag:aws:autoscaling:groupName,Values=${asgName} --output=text --query="Reservations[*].Instances[*].InstanceId"); do
  if [[ $instance == $ec2LeaderId ]]; then
    log "Set tag Swarm-Leader=true to $instance"
    aws ec2 create-tags --resource "$instance" --tag Key=Swarm-Leader,Value=true --region ${region}
    [[ $? -gt 0 ]] && logerr "Error adding tag Swarm-Leader from instance ID $instance"
  else
    log "Remove if exists tag Swarm-Leader=true to $instance"
    aws ec2 delete-tags --resource "$instance" --tag Key=Swarm-Leader --region ${region}
    [[ $? -gt 0 ]] && logerr "Error removing tag Swarm-Leader from instance ID $instance"
  fi
done

log "Finished successfully"



