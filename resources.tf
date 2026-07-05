resource "aws_vpc" "main" {
  cidr_block = var.vpc_cidr
}

resource "aws_internet_gateway" "main-gw" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "main"
  }
}

resource "aws_route_table" "main-rt" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main-gw.id
  }

  tags = {
    Name = "main-rt"
  }
}

resource "aws_subnet" "main-public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = cidrsubnet(var.vpc_cidr, 8, 1)
  availability_zone       = "us-east-1a"
  map_public_ip_on_launch = true

  tags = {
    Name = "Main-Public"
  }
}

resource "aws_route_table_association" "public-subnet" {
  subnet_id      = aws_subnet.main-public.id
  route_table_id = aws_route_table.main-rt.id
}

resource "aws_security_group" "main_sg" {
  name   = "main-sg"
  vpc_id = aws_vpc.main.id

  dynamic "ingress" {
    for_each = toset([22, 8080])
    iterator = port
    content {
      from_port   = port.value
      to_port     = port.value
      protocol    = "tcp"
      cidr_blocks = ["0.0.0.0/0"]
    }
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_key_pair" "me-key" {
  key_name   = "me-key"
  public_key = file("~/.ssh/id_rsa.pub")
}

resource "aws_instance" "jenkins" {
  ami                    = data.aws_ami.ami.id
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.main-public.id
  vpc_security_group_ids = [aws_security_group.main_sg.id]
  key_name               = aws_key_pair.me-key.key_name
  user_data = <<-EOF
  #!/bin/bash
  set -e
  yum update -y
  yum install -y java-17-amazon-corretto
  curl -L -o /etc/yum.repos.d/jenkins.repo \
  https://pkg.jenkins.io/redhat-stable/jenkins.repo
  rpm --import https://pkg.jenkins.io/redhat-stable/jenkins.io-2023.key
  yum install -y jenkins
  systemctl enable jenkins
  systemctl start jenkins
  EOF
  tags = {
    Name = "jenkins-server"
  }
}

resource "aws_eip" "lb" {
  instance = aws_instance.jenkins.id
  domain   = "vpc"
}

resource "aws_eip_association" "eip_assoc" {
  instance_id   = aws_instance.jenkins.id
  allocation_id = aws_eip.lb.id
}