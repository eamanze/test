provider "aws" {
  region = "eu-west-1"
  # profile = "pet-adoption"
}

locals {
  name = "test"
  domain_name = "3ureka.com"
}

module "vpc" {
  source = "terraform-aws-modules/vpc/aws"
  name = "${local.name}-vpc"
  cidr = "10.0.0.0/16"
  azs            = ["eu-west-1a", "eu-west-1b"]
  public_subnets = ["10.0.1.0/24", "10.0.2.0/24"]
  private_subnets = ["10.0.3.0/24", "10.0.4.0/24"]
  single_nat_gateway = true
  enable_nat_gateway = true
  tags = {
    Name = local.name
  }
}

resource "aws_iam_role" "bastion_ssm_role" {
  name = "${local.name}-bastion-ssm-role"
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

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.bastion_ssm_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}
resource "aws_iam_instance_profile" "bastion_profile" {
  name = "${local.name}-bastion-instance-profile"
  role = aws_iam_role.bastion_ssm_role.name
}

resource "aws_security_group" "bastion_sg" {
  name        = "${local.name}-bastion-sg"
  description = "Allow egress for SSM access"
  vpc_id      = module.vpc.vpc_id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = {
    Name = "${local.name}-bastion-sg"
  }
}

# Data source to get the latest Ubuntu AMI
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical
  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }
  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

resource "aws_launch_template" "bastion_lt" {
  name_prefix   = "${local.name}-bastion-lt"
  image_id      = data.aws_ami.ubuntu.id
  instance_type = "t2.micro"
  user_data = base64encode(templatefile("./bastion_userdata.sh", {
    private_keypair_path = tls_private_key.key.private_key_pem,
  }))
  iam_instance_profile { name = aws_iam_instance_profile.bastion_profile.name }
  lifecycle { create_before_destroy = true }
  network_interfaces {
    associate_public_ip_address = true
    security_groups             = [aws_security_group.bastion_sg.id]
  }
  tags = {
    Name = "${local.name}-bastion-lt"
  }
}

resource "aws_autoscaling_group" "bastion_asg" {
  name                = "${local.name}-bastion-asg"
  max_size            = 3
  min_size            = 1
  vpc_zone_identifier = module.vpc.public_subnets
  launch_template {
    id      = aws_launch_template.bastion_lt.id
    version = "$Latest"
  }
  tag {
    key                 = "Name"
    value               = "${local.name}-bastion-asg"
    propagate_at_launch = true
  }
  lifecycle {
    create_before_destroy = true
  }
}

# Creating the Security Group for Production Environment
resource "aws_security_group" "prod_sg" {
  name        = "${local.name}-prod-sg"
  description = "Security group for prod-env"
  vpc_id      = module.vpc.vpc_id
  ingress {
    description = "Port"
    from_port   = 3000
    to_port     = 3000
    protocol    = "tcp"
    security_groups = [ aws_security_group.prod_lb_sg.id ]
  }
  # SSH Access - Only allow traffic from the Bastion security group
  ingress {
    description     = "SSH from Bastion"
    from_port       = 22
    to_port         = 22
    protocol        = "tcp"
    security_groups = [aws_security_group.bastion_sg.id] # Allow SSH only from Bastion SG
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = {
    Name = "${local.name}-prod-sg"
  }
}

# creating keypair RSA key
resource "tls_private_key" "key" {
  algorithm = "RSA"
  rsa_bits  = 4096
}
resource "local_file" "key" {
  content         = tls_private_key.key.private_key_pem
  filename        = "${local.name}-key.pem"
  file_permission = 400
}
# creating public-key
resource "aws_key_pair" "public-key" {
  key_name   = "${local.name}-public-key"
  public_key = tls_private_key.key.public_key_openssh
} 

# Launch Template Configuration for EC2 Instances
resource "aws_launch_template" "prod_lnch_tmpl" {
  name_prefix   = "${local.name}-prod_tmpl"
  image_id      = data.aws_ami.ubuntu.id
  instance_type = "t2.medium"
  key_name      = aws_key_pair.public-key.key_name
  user_data = filebase64("${path.module}/docker_userdata.sh")
#   user_data = base64encode(templatefile("./module/prod-env/docker-script.sh", {
#     nexus-ip             = var.nexus-ip,
#     nr-key               = var.nr-key,
#     nr-acct-id           = var.nr-acct-id
#   }))
  network_interfaces {
    security_groups = [aws_security_group.prod_sg.id]
  }
}

# Create Auto Scaling Group (ASG) for Production
resource "aws_autoscaling_group" "prod_asg" {
  name                      = "${local.name}-prod-asg"
  max_size                  = 3
  min_size                  = 1
  desired_capacity          = 1
  health_check_type         = "EC2"
  health_check_grace_period = 120
  force_delete              = true
  launch_template {
    id      = aws_launch_template.prod_lnch_tmpl.id
    version = "$Latest"
  }
  vpc_zone_identifier = module.vpc.private_subnets
  target_group_arns   = [aws_lb_target_group.team1_prod_target_group.arn]
  tag {
    key                 = "Name"
    value               = "${local.name}-prod-asg"
    propagate_at_launch = true
  }
}

# Auto Scaling Policy for Dynamic Scaling
resource "aws_autoscaling_policy" "prod_team1_asg_policy" {
  autoscaling_group_name = aws_autoscaling_group.prod_asg.name
  name                   = "${local.name}-prod-team1-asg-policy"
  adjustment_type        = "ChangeInCapacity"
  policy_type            = "TargetTrackingScaling"

  target_tracking_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ASGAverageCPUUtilization"
    }
    target_value = 50.0
  }
}

#creating security group for loadbalancer
resource "aws_security_group" "prod_lb_sg" {
  name = "${local.name}-prod-lb-sg"
  description = "Allow inbound traffic from port 80 and 443"
  vpc_id = module.vpc.vpc_id
  ingress {
    description      = "https access"
    from_port        = 443
    to_port          = 443
    protocol         = "tcp"
    cidr_blocks      = ["0.0.0.0/0"]
  }
  egress {
    from_port        = 0
    to_port          = 0
    protocol         = "-1"
    cidr_blocks      = ["0.0.0.0/0"]
  }
  tags = {
    Name = "${local.name}-prod-lb-sg"
  }
}

# create application load balancer for prod
resource "aws_lb" "prod_lb" {
  name               = "${local.name}-prod-lb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.prod_lb_sg.id]
  subnets            = module.vpc.public_subnets
  enable_deletion_protection = false
  tags   = {
    Name = "${local.name}-prod-lb"
  }
}

# create target group for prod
resource "aws_lb_target_group" "team1_prod_target_group" {
  name        = "${local.name}-prod-tg"
  target_type = "instance"
  port        = 3000
  protocol    = "HTTP"
  vpc_id      = module.vpc.vpc_id

  health_check {
    enabled             = true
    interval            = 30
    path                = "/"
    matcher             = "200" 
    timeout             = 5
    healthy_threshold   = 5
    unhealthy_threshold = 5
  }

  lifecycle {
    create_before_destroy = true
  }
}

# create a listener on port 80 with redirect action
resource "aws_lb_listener" "prod_http_listener" {
  load_balancer_arn = aws_lb.prod_lb.arn
  port              = 80
  protocol          = "HTTP"
  default_action {
    type = "redirect"
    redirect {
      port        = 443
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }
}

# create a listener on port 443 with forward action
resource "aws_lb_listener" "prod_https_listener" {
  load_balancer_arn  = aws_lb.prod_lb.arn
  port               = 443
  protocol           = "HTTPS"
  ssl_policy         = "ELBSecurityPolicy-2016-08"
  certificate_arn    = aws_acm_certificate.acm-cert.arn
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.team1_prod_target_group.arn
  }
}

# get details about a route 53 hosted zone
data "aws_route53_zone" "hosted_zone" {
  name         = local.domain_name
  private_zone = false
}


# create a record set for production
resource "aws_route53_record" "prod_record" {
  zone_id = data.aws_route53_zone.hosted_zone.zone_id
  name    = "prodtest.${local.domain_name}"
  type    = "A"
  alias {
    name                   = aws_lb.prod_lb.dns_name
    zone_id                = aws_lb.prod_lb.zone_id
    evaluate_target_health = true
  }
}

# Create ACM certificate with DNS validation
resource "aws_acm_certificate" "acm-cert" {
  domain_name               = local.domain_name
  subject_alternative_names = ["*.${local.domain_name}"]
  validation_method         = "DNS"
  lifecycle {
    create_before_destroy = true
  }

  tags = {
    Name = "${local.name}-acm-cert"
  }
}

# Fetch DNS Validation Records for ACM Certificate
resource "aws_route53_record" "acm_validation_record" {
  for_each = {
    for dvo in aws_acm_certificate.acm-cert.domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  }

  # Create DNS Validation Record for ACM Certificate
  zone_id         = data.aws_route53_zone.hosted_zone.zone_id
  allow_overwrite = true
  name            = each.value.name
  type            = each.value.type
  ttl             = 60
  records         = [each.value.record]
  depends_on      = [aws_acm_certificate.acm-cert]
}

# Validate the ACM Certificate after DNS Record Creation
resource "aws_acm_certificate_validation" "team2_cert_validation" {
  certificate_arn         = aws_acm_certificate.acm-cert.arn
  validation_record_fqdns = [for record in aws_route53_record.acm_validation_record : record.fqdn]
  depends_on              = [aws_acm_certificate.acm-cert]
}