#!/bin/bash
yum update -y
# Install Amazon SSM Agent - Note: ${region} should be passed via templatefile in Terraform
dnf install -y https://s3."${region}".amazonaws.com/amazon-ssm-"${region}"/latest/linux_amd64/amazon-ssm-agent.rpm
curl "https://s3.amazonaws.com/session-manager-downloads/plugin/latest/linux_64bit/session-manager-plugin.rpm" -o "session-manager-plugin.rpm"
yum install -y session-manager-plugin.rpm
yum install wget -y
yum install maven -y
yum install git pip unzip -y
# Installing awscli
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip awscliv2.zip
sudo ./aws/install
sudo ln -svf /usr/local/bin/aws /usr/bin/aws
# Install Jenkins
wget -O /etc/yum.repos.d/jenkins.repo https://pkg.jenkins.io/redhat-stable/jenkins.repo
rpm --import https://pkg.jenkins.io/redhat-stable/jenkins.io-2023.key
yum upgrade -y
yum install java-17-openjdk -y
yum install jenkins -y
sed -i 's/^User=jenkins/User=root/' /usr/lib/systemd/system/jenkins.service
systemctl daemon-reload
systemctl start jenkins
systemctl enable jenkins
systemctl start jenkins
# Install trivy for container scanning
RELEASE_VERSION=$(grep -Po '(?<=VERSION_ID=")[0-9]' /etc/os-release)
cat << EOT | sudo tee -a /etc/yum.repos.d/trivy.repo
[trivy]
name=Trivy repository
baseurl=https://aquasecurity.github.io/trivy-repo/rpm/releases/$RELEASE_VERSION/\$basearch/
gpgcheck=0
enabled=1
EOT
yum -y update
yum -y install trivy
# install docker
curl -fsSL https://get.docker.com -o get-docker.sh
sudo sh get-docker.sh
rm get-docker.sh
usermod -aG docker ubuntu
echo "Docker installed and user added to docker group."
echo "Starting Docker service..."
systemctl start docker
systemctl enable docker
echo "Docker service started and enabled to start on boot."
hostnamectl set-hostname jenkins-server