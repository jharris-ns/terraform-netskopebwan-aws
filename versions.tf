#------------------------------------------------------------------------------
#  Copyright (c) 2022 Infiot Inc.
#  All rights reserved.
#------------------------------------------------------------------------------

terraform {
  required_version = ">=0.13"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 4.30"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.7.2"
    }
    netskopebwan = {
      source  = "netskopeoss/netskopebwan"
      version = "0.0.2"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.0"
    }
    utils = {
      source = "cloudposse/utils"
    }
  }
}