variable "name" {
  description = "Name to be used on all the resources as identifier."
  type        = string
  default     = "greeter-stack"
}

variable "region" {
  description = "AWS region."
  type        = string
  default     = "us-east-2"
}

variable "lb_ingress_ip" {
  description = "Your IP. This is used in the load balancer security groups to ensure only you can access the Consul UI and example application."
  type        = string
  default = "97.126.29.97"
}