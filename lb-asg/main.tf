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

resource "aws_vpc" "lbvpc" {
    cidr_block = "10.0.0.0/16"
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.lbvpc.id
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.lbvpc.id
}



resource "aws_subnet" "lbsubnet-a" {
    vpc_id  = aws_vpc.lbvpc.id
    cidr_block = "10.0.1.0/24"
    availability_zone = "us-east-1a"
}

resource "aws_subnet" "lbsubnet-b" {
    vpc_id            = aws_vpc.lbvpc.id
  cidr_block        = "10.0.2.0/24"
  availability_zone = "us-east-1b"
}

resource "aws_route" "public_default" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.igw.id
}

resource "aws_route_table_association" "pub_a" {
  subnet_id      = aws_subnet.lbsubnet-a.id
  route_table_id = aws_route_table.public.id
}
resource "aws_route_table_association" "pub_b" {
  subnet_id      = aws_subnet.lbsubnet-b.id
  route_table_id = aws_route_table.public.id
}


resource "aws_security_group" "instance_sg" {
  name   = "instance-sg"
  vpc_id = aws_vpc.lbvpc.id

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"] # tighten in prod
  }
  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"] # tighten in prod
  }
}

resource "aws_iam_role" "ec2" {
  name = "ec2-role"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
}
data "aws_iam_policy_document" "ec2_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_instance_profile" "ec2_profile" {
  name = "ec2-profile"
  role = aws_iam_role.ec2.name
}

resource "aws_launch_template" "lt" {
  name_prefix   = "myapp-"
  image_id      = "ami-0f57da8ea7b9e2a4e" # replace with a valid AMI in your region
  instance_type = "t2.micro"

  iam_instance_profile {
    name = aws_iam_instance_profile.ec2_profile.name
  }
  user_data = base64encode(file("${path.module}/user_data.sh"))

  network_interfaces {
    associate_public_ip_address = true
    security_groups             = [aws_security_group.instance_sg.id]
  }
}

resource "aws_lb" "nlb" {
    name = "demo-nlb"
    internal = false
    load_balancer_type = "network"
    subnets = [aws_subnet.lbsubnet-a.id, aws_subnet.lbsubnet-b.id]
}

resource "aws_lb_target_group" "tg" {
  name        = "example-tg"
  port        = 80
  protocol    = "TCP"
  vpc_id      = aws_vpc.lbvpc.id
  target_type = "instance"

  health_check {
    protocol = "TCP"
    port     = "traffic-port"
    # for HTTP health check with NLB you need target group protocol = "HTTP" (supported)
  }
}

resource "aws_lb_listener" "listener" {
  load_balancer_arn = aws_lb.nlb.arn
  port              = 80
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.tg.arn
  }
}

resource "aws_autoscaling_group" "asg" {
  name                      = "example-asg"
  max_size                  = 3
  min_size                  = 1
  desired_capacity          = 1
  vpc_zone_identifier       = [aws_subnet.lbsubnet-a.id, aws_subnet.lbsubnet-b.id]
  launch_template {
    id      = aws_launch_template.lt.id
    version = "$Latest"
  }

  target_group_arns = [aws_lb_target_group.tg.arn]

  tag {
    key                 = "Name"
    value               = "example-instance"
    propagate_at_launch = true
  }
}

resource "aws_autoscaling_policy" "cpu_target_tracking" {
  name                   = "asg-cpu-target-tracking"
  autoscaling_group_name = aws_autoscaling_group.asg.name
  policy_type            = "TargetTrackingScaling"

  target_tracking_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ASGAverageCPUUtilization"
    }

    target_value               = 50.0
    //estimated_instance_warmup  = 300   # ✅ CORRECT LOCATION
    disable_scale_in           = false
    //health_check_grace_period  = 300
  }
}

resource "aws_autoscaling_policy" "scale_in" {
  name                   = "asg-scale-in-policy"
  autoscaling_group_name = aws_autoscaling_group.asg.name
  policy_type            = "SimpleScaling"

  adjustment_type         = "ChangeInCapacity"
  scaling_adjustment      = -1     # SCALE IN (remove 1 instance)
  cooldown                = 300
}


resource "aws_cloudwatch_metric_alarm" "cpu_low" {
  alarm_name          = "asg-cpu-low"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 2
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = 120
  statistic           = "Average"
  threshold           = 30

  dimensions = {
    AutoScalingGroupName = aws_autoscaling_group.asg.name
  }

  alarm_actions = [aws_autoscaling_policy.scale_in.arn]
}
