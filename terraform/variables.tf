variable "region" {
  type    = string
  default = "ap-south-1"
}

variable "aws_profile" {
  type    = string
  default = "infrathrone-demo"
}

variable "cluster_name" {
  type    = string
  default = "karpenter-demo"
}

variable "kubernetes_version" {
  # Karpenter v1.14 supports up to 1.36
  type    = string
  default = "1.36"
}

variable "api_allowed_cidrs" {
  type    = list(string)
  default = ["0.0.0.0/0"]
}
