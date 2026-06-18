# Remote state backend — partial configuration.
#
# Supply your own S3 bucket + DynamoDB lock table (both in YOUR account)
# at init time:
#
#   terraform init -backend-config=backend.hcl
#
# where backend.hcl contains, e.g.:
#
#   bucket         = "mycompany-codevine-gateway-tfstate"
#   key            = "gateway/terraform.tfstate"
#   region         = "us-east-1"
#   dynamodb_table = "mycompany-codevine-gateway-tflocks"
#   encrypt        = true
#
# To use local state instead (not recommended for teams), delete this file.

terraform {
  backend "s3" {}
}
