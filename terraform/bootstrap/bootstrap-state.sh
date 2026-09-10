#!/usr/bin/env bash
# Create the Terraform state bucket for one AWS account.
#
#   export AWS_PROFILE=<sso-profile>
#   ./terraform/bootstrap/bootstrap-state.sh
#
# Four AWS CLI calls rather than a Terraform module, because state cannot live
# in a bucket Terraform has not created yet. Doing it in Terraform means local
# state to migrate afterwards and a module that runs exactly once per account
# and is then never read again.
#
# Run once per account. Idempotent: an existing bucket is left alone.
set -euo pipefail

ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
REGION=${AWS_REGION:-us-east-1}
BUCKET="exerra-tfstate-${ACCOUNT}"

echo "account ${ACCOUNT}, region ${REGION}, bucket ${BUCKET}"

if aws s3api head-bucket --bucket "$BUCKET" 2>/dev/null; then
  echo "bucket already exists; leaving it alone"
else
  # us-east-1 is the one region where create-bucket must NOT be given a
  # LocationConstraint. Passing one there fails with InvalidLocationConstraint.
  if [ "$REGION" = "us-east-1" ]; then
    aws s3api create-bucket --bucket "$BUCKET" --region "$REGION"
  else
    aws s3api create-bucket --bucket "$BUCKET" --region "$REGION" \
      --create-bucket-configuration "LocationConstraint=$REGION"
  fi
  echo "created"
fi

# Versioning is the point of this script. A corrupted or truncated state file is
# recoverable from a versioned bucket and rebuilt by hand otherwise.
aws s3api put-bucket-versioning --bucket "$BUCKET" \
  --versioning-configuration Status=Enabled

aws s3api put-bucket-encryption --bucket "$BUCKET" \
  --server-side-encryption-configuration \
  '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'

aws s3api put-public-access-block --bucket "$BUCKET" \
  --public-access-block-configuration \
  'BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true'

echo
echo "done. Put this in terraform/envs/<env>/backend.hcl:"
echo "  bucket = \"${BUCKET}\""
echo "  region = \"${REGION}\""
