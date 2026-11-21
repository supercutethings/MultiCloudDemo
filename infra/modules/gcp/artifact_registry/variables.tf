variable "project" {
  type = string
}

variable "region" {
  type = string
}

variable "repository_id" {
  description = "Repository name. Must be unique within the region."
  type        = string
}

variable "description" {
  type    = string
  default = "Showcase service images"
}

variable "reader_members" {
  description = "IAM members that may pull, e.g. `serviceAccount:showcase-auth@project.iam.gserviceaccount.com`."
  type        = list(string)
  default     = []
}

variable "labels" {
  type    = map(string)
  default = {}
}
