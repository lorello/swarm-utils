# Docker Swarm Utilities

Utilities in this repo are used on my setup of docker swarm on EC2

## My setup on AWS EC2

 - 1 autoscaling group for 3 managers node
 - 1 autoscaling group for N workers (currently using a variable number of nodes between 15-30)

Each autoscaling groups has a Launch Template that contains:

 - AMI: Ubuntu LTS
 - disk layout: 1 root partition of 20 GB, 1 data partition of 50GB mounted on /var/lib/docker
 - setup the docker-ce repo and install docker-ce package
 - join the cluster
 - add a daily cronjob to clean-up all died containers and unused resources (images, volumes, networks)
 - setup users with docker group
 - setup cloudwatch agent

The workers are automatically added to a target group of ec2 nodes. A Network Load Balancer bring
TCP traffic from outside to the worker node where Traefik listen on a single node on ports
80, 443, 8080.


