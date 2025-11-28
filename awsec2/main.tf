terraform {
  required_providers {
    aws = {
      source = "hashicorp/aws"
      version = "6.23.0"
    }
  }
}

provider "aws" {
  # Configuration options
}

resource "aws_vpc" "main_vpc" {
  cidr_block = "10.0.0.0/16"
#   instance_tenancy = "default"
#   enable_dns_support = true
#   enable_dns_hostnames = true

  tags = {
    Name = "my-terraform-vpc"
    Environment = "dev"
  }
}
resource "aws_internet_gateway" "gw" {
  vpc_id = aws_vpc.main_vpc.id

  tags = {
    Name = "main"
  }
}


resource "aws_route_table" "public_rt" {
  vpc_id = aws_vpc.main_vpc.id

  tags = {
    Name = "public-route-table"
  }
}


resource "aws_route" "public_internet_access" {
  route_table_id         = aws_route_table.public_rt.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.gw.id
}

resource "aws_route_table_association" "public_assoc" {
  subnet_id      = aws_subnet.demosubnet.id
  route_table_id = aws_route_table.public_rt.id
}


resource "aws_subnet" "demosubnet" {
  cidr_block        = "10.0.1.0/24"
  vpc_id = aws_vpc.main_vpc.id
  availability_zone = "us-east-1a"
    tags = {
        Name ="demosubnet"
    }
}

resource "aws_security_group" "demosg" {
  name        = "demosg"
  description = "Security group for example instances"
  vpc_id      = aws_vpc.main_vpc.id # Assuming 'aws_vpc.main' is a defined VPC resource 

  ingress {
    description      = "Allow HTTP from anywhere"
    from_port        = 80
    to_port          = 80
    protocol         = "tcp"
    cidr_blocks      = ["0.0.0.0/0"]
  }

  ingress {
    description      = "Allow SSH from specific IP"
    from_port        = 22
    to_port          = 22
    protocol         = "tcp"
    cidr_blocks      = ["0.0.0.0/0"] # Replace with your specific IP range
  }

  egress {
    description      = "Allow all outbound traffic"
    from_port        = 0
    to_port          = 0
    protocol         = "-1" # Represents all protocols
    cidr_blocks      = ["0.0.0.0/0"]
  }

  tags = {
    Name = "demosg"
  }
}

resource "aws_instance" "linux_instance" {
 ami             = "ami-0ecb62995f68bb549"
 instance_type   = "t2.micro"
 key_name        = "lal"
 subnet_id       = aws_subnet.demosubnet.id
 associate_public_ip_address = true 
 vpc_security_group_ids = [aws_security_group.demosg.id]

 tags = {
   Name = "demovm"
 }

}