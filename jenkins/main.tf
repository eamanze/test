provider "aws" {
  region = "eu-west-1"
  profile = "pet-adoption"
}

locals {
  name = "jenkins"
}

module "vpc" {
  source = "terraform-aws-modules/vpc/aws"
  name = "${local.name}-vpc"
  cidr = "10.0.0.0/16"
  azs            = ["eu-west-1a"]
  public_subnets = ["10.0.1.0/24"]
  enable_nat_gateway = false
  enable_vpn_gateway = false
  tags = {
    Name = local.name
  }
}

data "aws_ami" "latest_rhel" {
  most_recent = true
  # Red Hat's official AWS account ID
  owners = ["309956199498"]
  filter {
    name   = "name"
    values = ["RHEL-9*-x86_64-*"]
  }
  filter {
    name   = "architecture"
    values = ["x86_64"]
  }
  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

#creating and attaching an IAM role with SSM permissions to the instance.
resource "aws_iam_role" "jenkins_ssm_role" {
  name = "${local.name}-ssm-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Effect = "Allow",
      Principal = {
        Service = "ec2.amazonaws.com"
      },
      Action = "sts:AssumeRole"
    }]
  })
}

#Attach the AmazonSSMManagedInstanceCore policy
# — required for Session Manager and SSM Agent functionality.
resource "aws_iam_role_policy_attachment" "jenkins_ssm_attachment" {
  role       = aws_iam_role.jenkins_ssm_role.id
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}
#Attaching AdministratorAccess (this grants full access to AWS resources)
resource "aws_iam_role_policy_attachment" "jenkins-admin_access_attachment" {
  role       = aws_iam_role.jenkins_ssm_role.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}
# create instance profiles- as EC2 instances can’t assume roles directly
resource "aws_iam_instance_profile" "jenkins_ssm_profile" {
  name = "${local.name}-ssm-instance-profile"
  role = aws_iam_role.jenkins_ssm_role.id
}

# Create a security group
resource "aws_security_group" "jenkins_sg" {
  name        = "${local.name}-jenkins_sg"
  description = "Allow Jenkins without ssh"
  vpc_id      = module.vpc.vpc_id # Attach to the created VPC
  # Inbound rule for Jenkins web interface
  ingress {
    description = "Allow HTTP traffic to Jenkins"
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"] # Open to the world (can restrict for security)
  }
  # Allow all outbound traffic
  egress {
    description = "Allow all outbound traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1" # All protocols
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# Launch an EC2 instance for Jenkins
resource "aws_instance" "jenkins" {
  ami                         = data.aws_ami.latest_rhel.id        # AMI ID passed as a variable (e.g., RHEL)
  instance_type               = "t2.medium"                        # Instance type (e.g., t3.medium)
  subnet_id                   = module.vpc.public_subnets[0]    # Use first available subnet
  vpc_security_group_ids      = [aws_security_group.jenkins_sg.id] # Attach security group       # Use the created key pair
  associate_public_ip_address = true                               # Required for SSH and browser access
  iam_instance_profile        = aws_iam_instance_profile.jenkins_ssm_profile.name
  root_block_device {
    volume_size = 20
    volume_type = "gp3"
    encrypted   = true
  }
  # User data script to install Jenkins and required tools
  user_data = templatefile("./jenkins_userdata.sh", {
    region = var.region
  })
  metadata_options {
    http_tokens = "required"
  }
  # Tag the instance for easy identification
  tags = {
    Name = "${local.name}-jenkins-server"
  }
}
