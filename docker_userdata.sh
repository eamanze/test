#!/bin/bash
apt-get update -y
curl -fsSL https://get.docker.com -o get-docker.sh
sudo sh get-docker.sh
rm get-docker.sh
usermod -aG docker ubuntu
echo "Docker installed and user added to docker group."
echo "Starting Docker service..."
systemctl start docker
systemctl enable docker
echo "Docker service started and enabled to start on boot."
hostnamectl set-hostname prodtest-server