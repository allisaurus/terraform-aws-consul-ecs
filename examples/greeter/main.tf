terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "3.42.0"
    }
  }
}

provider "aws" {
  region = var.region
}


// from file in other example
resource "aws_ecs_cluster" "this" {
  name               = var.name
  capacity_providers = ["FARGATE"]
}

// missing log group?
resource "aws_cloudwatch_log_group" "log_group" {
  name = var.name
}

// needed by my VPC setup
data "aws_availability_zones" "available" {
  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

data "aws_security_group" "vpc_default" {
  name   = "default"
  vpc_id = module.vpc.vpc_id  // diff than docs
}

module "dev_consul_server" {
  source  = "../../modules/dev-server" // diff than docs

  name                        = "${var.name}-dev-server"
  ecs_cluster_arn             = aws_ecs_cluster.this.arn
  subnet_ids                  = module.vpc.private_subnets
  lb_vpc_id                   = module.vpc.vpc_id
  lb_enabled       = true  // name of param different
  lb_subnets                  = module.vpc.public_subnets
  lb_ingress_rule_cidr_blocks = ["${var.lb_ingress_ip}/32"]
  log_configuration = {
    logDriver = "awslogs"
    options = {
      awslogs-group         = aws_cloudwatch_log_group.log_group.name
      awslogs-region        = var.region
      awslogs-stream-prefix = "consul-server"
    }
  }
}

resource "aws_security_group_rule" "ingress_from_server_alb_to_ecs" {
  type                     = "ingress"
  from_port                = 8500
  to_port                  = 8500
  protocol                 = "tcp"
  source_security_group_id = module.dev_consul_server.lb_security_group_id
  security_group_id        = data.aws_security_group.vpc_default.id
}

output "consul_server_url" {
  value = "http://${module.dev_consul_server.lb_dns_name}:8500"
}


// common task role

data "aws_caller_identity" "this" {}

resource "aws_iam_role" "greeter_task" {
  name = "greeter_task"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Sid    = ""
        Principal = {
          Service = "ecs-tasks.amazonaws.com"
        }
      },
    ]
  }) 

  inline_policy {
    name = "greeter_task"
    policy = jsonencode({
      Version = "2012-10-17"
      Statement = [
        {
          Effect = "Allow"
          Action = [
            "ecs:ListTasks",
          ]
          Resource = "*"
        },
        {
          Effect = "Allow"
          Action = [
            "ecs:DescribeTasks"
          ]
          Resource = [
            "arn:aws:ecs:${var.region}:${data.aws_caller_identity.this.account_id}:task/*",
          ]
        }
      ]
    })
  }
}



// GREETING task def, service

module "greeting_task_def" {
  source  = "../../modules/mesh-task" // from this repo

  family              = "greeting"
  execution_role_arn  = "arn:aws:iam::679273379347:role/ecsTaskExecutionRole" // mine
  task_role_arn       = aws_iam_role.greeter_task.arn
  container_definitions = [
    {
      name             = "example-client-app"
      image            = "nathanpeck/greeting"
      essential        = true
      portMappings = [  // needed?
        {
          containerPort = 3000
          hostPort      = 3000
          protocol      = "tcp"
        }
      ]
      cpu         = 0
      mountPoints = []
      volumesFrom = []
      environment = [
        {
          name = "PORT"
          value = "3000"
        }
      ]
    }
  ]

  port                       = "3000"
  consul_server_service_name = module.dev_consul_server.ecs_service_name
}

resource "aws_ecs_service" "greeting_service" {
  name = "greeting"
  cluster = aws_ecs_cluster.this.arn
  task_definition = module.greeting_task_def.task_definition_arn
  desired_count = 2
  network_configuration {
    subnets = module.vpc.private_subnets
  }
  launch_type            = "FARGATE"
  propagate_tags         = "TASK_DEFINITION"
  depends_on = [
    aws_iam_role.greeter_task
  ]
}


// NAME service

module "name_task_def" {
  source  = "../../modules/mesh-task" // from this repo

  family              = "name"
  execution_role_arn  = "arn:aws:iam::679273379347:role/ecsTaskExecutionRole" // mine
  task_role_arn       = aws_iam_role.greeter_task.arn
  container_definitions = [
    {
      name             = "example-client-app"
      image            = "nathanpeck/name"
      essential        = true
      portMappings = [  // needed?
        {
          containerPort = 3000
          hostPort      = 3000
          protocol      = "tcp"
        }
      ]
      cpu         = 0
      mountPoints = []
      volumesFrom = []
      environment = [
        {
          name = "PORT"
          value = "3000"
        }
      ]
    }
  ]

  port                       = "3000"
  consul_server_service_name = module.dev_consul_server.ecs_service_name
}

resource "aws_ecs_service" "name_service" {
  name = "name"
  cluster = aws_ecs_cluster.this.arn
  task_definition = module.name_task_def.task_definition_arn
  desired_count = 2
  network_configuration {
    subnets = module.vpc.private_subnets
  }
  launch_type            = "FARGATE"
  propagate_tags         = "TASK_DEFINITION"
  depends_on = [
    aws_iam_role.greeter_task
  ]
}


// GREETER service

module "greeter_task_def" {
  source  = "../../modules/mesh-task" // from this repo

  family              = "greeter"
  execution_role_arn  = "arn:aws:iam::679273379347:role/ecsTaskExecutionRole" // mine
  task_role_arn       = aws_iam_role.greeter_task.arn
  container_definitions = [
    {
      name             = "greeter"
      image            = "nathanpeck/greeter"
      essential        = true
      portMappings = [  // needed?
        {
          containerPort = 3000
          hostPort      = 3000
          protocol      = "tcp"
        }
      ]
      cpu         = 0
      mountPoints = []
      volumesFrom = []
      environment = [
        {
          name = "PORT"
          value = "3000"
        },
        {
          name = "NAME_URL"
          value = "http://localhost:3001"
        },
        {
          name = "GREETING_URL"
          value = "http://localhost:3002"
        }
      ]
    }
  ]
  upstreams = [
    {
      destination_name = "name"
      local_bind_port = 3001
    },
    {
      destination_name = "greeting"
      local_bind_port = 3002
    }
  ]
  /*environment = [ // as shown in docs but doesn't work
    {
      name = "NAME_URL"
      value = "http://localhost:3001"
    },
    {
      name = "GREETING_URL"
      value = "http://localhost:3002"
    }
  ]*/

  port                       = "3000"
  consul_server_service_name = module.dev_consul_server.ecs_service_name
}

resource "aws_ecs_service" "greeter_service" {
  name = "greeter"
  cluster = aws_ecs_cluster.this.arn
  task_definition = module.greeter_task_def.task_definition_arn
  desired_count = 2
  network_configuration {
    subnets = module.vpc.private_subnets
  }
  launch_type            = "FARGATE"
  propagate_tags         = "TASK_DEFINITION"
  depends_on = [
    aws_iam_role.greeter_task
  ]
}