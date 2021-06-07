#!/bin/bash -l
set -e

RESET_TEXT='\033[0m'
RED='\033[0;31m'
GREEN='\033[0;32m'
ORANGE='\033[0;33m'
BLUE='\033[0;34m'


# 0) Validation
if [ -z "$INPUT_CODEDEPLOY_NAME" ]; then
    echo "::error::codedeploy_name is required and must not be empty."
    exit 1;
fi

if [ -z "$INPUT_CODEDEPLOY_GROUP" ]; then
    echo "::error::codedeploy_group is required and must not be empty."
    exit 1;
fi

if [ -z "$INPUT_AWS_ACCESS_KEY" ]; then
    echo "::error::aws_access_key is required and must not be empty."
    exit 1;
fi

if [ -z "$INPUT_AWS_SECRET_KEY" ]; then
    echo "::error::aws_secret_key is required and must not be empty."
    exit 1;
fi

if [ -z "$INPUT_S3_BUCKET" ]; then
    echo "::error::s3_bucket is required and must not be empty."
    exit 1;
fi

echo "::debug::Input variables correctly validated."

# 1) Load our permissions in for aws-cli
export AWS_ACCESS_KEY_ID=$INPUT_AWS_ACCESS_KEY
export AWS_SECRET_ACCESS_KEY=$INPUT_AWS_SECRET_KEY
export AWS_DEFAULT_REGION=$INPUT_AWS_REGION

function fileExists() {
  aws s3api head-object \
     --bucket "$INPUT_S3_BUCKET" \
     --key "$1" \
     --query ETag --output text > /dev/null 2>&1 && return 1 || return 0
}

echo "::debug::codebuild_id $INPUT_CODEBUILD_ID"
if [ "$INPUT_CODEBUILD_ID" ]; then
  echo "::debug::codebuild_id is present. traying to load s3 folder from that build."
  INPUT_S3_BUCKET=$(aws codebuild batch-get-builds --ids $INPUT_CODEBUILD_ID | jq --raw-output '.builds|first.artifacts.location' | sed -E 's/arn:aws:s3:::([^\/]+)\/(.+)/\1/gm;t')
  INPUT_S3_FOLDER=$(aws codebuild batch-get-builds --ids $INPUT_CODEBUILD_ID | jq --raw-output '.builds|first.artifacts.location' | sed -E 's/arn:aws:s3:::([^\/]+)\/(.+)/\2/gm;t')
  echo "::set-output name=BUCKET::${INPUT_S3_BUCKET}"
  echo "::set-output name=FOLDER::${INPUT_S3_BUCKET}"
fi

while fileExists $INPUT_S3_FOLDER; do
  sleep 5
  echo "::debug::waiting File $INPUT_S3_FOLDER not exists."
done

# 3) Upload the deployment to S3, drop old archive.
function getArchiveETag() {
  aws s3api head-object \
     --bucket "$INPUT_S3_BUCKET" \
     --key "$INPUT_S3_FOLDER" \
     --query ETag --output text
}

ZIP_ETAG=$(getArchiveETag)

echo "::debug::Obtained ETag of uploaded S3 Zip Archive."

# 4) Start the CodeDeploy
function getActiveDeployments() {
    aws deploy list-deployments \
        --application-name "$INPUT_CODEDEPLOY_NAME" \
        --deployment-group-name "$INPUT_CODEDEPLOY_GROUP" \
        --include-only-statuses "Queued" "InProgress" |  jq -r '.deployments';
}

function getSpecificDeployment() {
    aws deploy get-deployment \
        --deployment-id "$1";
}

function pollForSpecificDeployment() {
    deadlockCounter=0;

    while true; do
        RESPONSE=$(getSpecificDeployment "$1")
        FAILED_COUNT=$(echo "$RESPONSE" | jq -r '.deploymentInfo.deploymentOverview.Failed')
        IN_PROGRESS_COUNT=$(echo "$RESPONSE" | jq -r '.deploymentInfo.deploymentOverview.InProgress')
        SKIPPED_COUNT=$(echo "$RESPONSE" | jq -r '.deploymentInfo.deploymentOverview.Skipped')
        SUCCESS_COUNT=$(echo "$RESPONSE" | jq -r '.deploymentInfo.deploymentOverview.Succeeded')
        PENDING_COUNT=$(echo "$RESPONSE" | jq -r '.deploymentInfo.deploymentOverview.Pending')
        STATUS=$(echo "$RESPONSE" | jq -r '.deploymentInfo.status')

        echo -e "${ORANGE}Deployment in progress. Sleeping 15 seconds. (Try $((++deadlockCounter)))";
        echo -e "Instance Overview: ${RED}Failed ($FAILED_COUNT), ${BLUE}In-Progress ($IN_PROGRESS_COUNT), ${RESET_TEXT}Skipped ($SKIPPED_COUNT), ${BLUE}Pending ($PENDING_COUNT), ${GREEN}Succeeded ($SUCCESS_COUNT)"
        echo -e "Deployment Status: $STATUS"

        if [ "$FAILED_COUNT" -gt 0 ]; then
            echo -e "${RED}Failed instance detected (Failed count over zero)."
            exit 1;
        fi

        if [ "$STATUS" = "Failed" ]; then
            echo -e "${RED}Failed deployment detected (Failed status)."
            exit 1;
        fi

        if [ "$STATUS" = "Succeeded" ]; then
            break;
        fi

        if [ "$deadlockCounter" -gt "$INPUT_MAX_POLLING_ITERATIONS" ]; then
            echo -e "${RED}Max polling iterations reached (max_polling_iterations)."
            exit 1;
        fi
        sleep 15s;
    done;
}

function pollForActiveDeployments() {
    deadlockCounter=0;
    while [ "$(getActiveDeployments)" != "[]" ]; do
        echo -e "${ORANGE}Deployment in progress. Sleeping 15 seconds. (Try $((++deadlockCounter)))";

        if [ "$deadlockCounter" -gt "$INPUT_MAX_POLLING_ITERATIONS" ]; then
            echo -e "${RED}Max polling iterations reached (max_polling_iterations)."
            exit 1;
        fi
        sleep 15s;
    done;
}
pollForActiveDeployments

# 5) Poll / Complete
function deployRevision() {
    aws deploy create-deployment \
        --application-name "$INPUT_CODEDEPLOY_NAME" \
        --deployment-group-name "$INPUT_CODEDEPLOY_GROUP" \
        --description "$GITHUB_REF - $GITHUB_SHA" \
        --s3-location bucket="$INPUT_S3_BUCKET",bundleType=zip,key="$INPUT_S3_FOLDER"/"$ZIP_FILENAME" | jq -r '.deploymentId'
}

function registerRevision() {
    aws deploy register-application-revision \
        --application-name "$INPUT_CODEDEPLOY_NAME" \
        --description "$GITHUB_REF - $GITHUB_SHA" \
        --s3-location bucket="$INPUT_S3_BUCKET",bundleType=zip,key="$INPUT_S3_FOLDER"/"$ZIP_FILENAME" > /dev/null 2>&1
}

if $INPUT_CODEDEPLOY_REGISTER_ONLY; then
    echo -e "${BLUE}Registering deployment to ${RESET_TEXT}$INPUT_CODEDEPLOY_GROUP.";
    registerRevision
    echo -e "${BLUE}Registered deployment to ${RESET_TEXT}$INPUT_CODEDEPLOY_GROUP!";
else
    echo -e "${BLUE}Deploying to ${RESET_TEXT}$INPUT_CODEDEPLOY_GROUP.";
    DEPLOYMENT_ID=$(deployRevision)

    sleep 10;
    pollForSpecificDeployment "$DEPLOYMENT_ID"
    echo -e "${GREEN}Deployed to ${RESET_TEXT}$INPUT_CODEDEPLOY_GROUP!";
fi

exit 0;
