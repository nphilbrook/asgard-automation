#!/bin/bash

# NOTE: This script require GNU sed. You can install it on macOS using Homebrew with `brew install gnu-sed` and then
# set your $PATH appropriately as per the gnu-sed instructions.

# requires a valid credentials file at ~/.terraform.d/credentials.tfrc.json for a TFE_TOKEN. This is used
# to set the workspace execution mode

# usage : ./setup.sh <tf_hostname> <tf_organization> <gh_organization> <pattern> <pattern_version> <app_name> <channel> <operation>

# NOTES:
# `apply` will create a workspace that doesn't exist (it is idempotent)
# `destroy` will delete the workspace after destroying all resources

set -euo pipefail

TF_HOSTNAME=$1
TF_CLOUD_ORGANIZATION=$2
GH_ORGANIZATION=$3
PATTERN=$4
PATTERN_VERSION=$5
APP_NAME=$6
CHANNEL=$7
OPERATION=$8

# TODO: validate operation is one of "apply", "destroy", "plan"

WORKDIR=$(mktemp -d)

TFE_TOKEN=$(cat ~/.terraform.d/credentials.tfrc.json|jq -r ".credentials[\"$TF_HOSTNAME\"].token")

# AGENT_POOL_ID=$(curl -s -H "Authorization: Bearer $TFE_TOKEN" -H "Content-Type: application/vnd.api+json" \
# -G --data-urlencode "q=asgard-agent-pool" \
# "https://app.terraform.io/api/v2/organizations/$TF_CLOUD_ORGANIZATION/agent-pools" | jq -r '.data[0].id')

mkdir -p $WORKDIR
echo "WORKDIR: $WORKDIR"
pushd $WORKDIR

git clone git@github.com:$GH_ORGANIZATION/tf-pattern-$PATTERN.git
pushd tf-pattern-$PATTERN
git checkout $PATTERN_VERSION

sed -i"" "s/__TF_HOSTNAME__/$TF_HOSTNAME/" main.tf backend.tf
sed -i"" "s/__TF_CLOUD_ORGANIZATION__/$TF_CLOUD_ORGANIZATION/" main.tf backend.tf
sed -i"" "s/__APP_NAME__/$APP_NAME/" main.tf
sed -i"" "s/__TF_CLOUD_PROJECT__/$APP_NAME/" backend.tf

SOURCE_DIR=$(dirs -l | cut -d' ' -f3)
cp $SOURCE_DIR/update-payload.json .
# sed -i"" "s/__AGENT_POOL_ID__/$AGENT_POOL_ID/" update-payload.json

FLAGS="-auto-approve"
if [[ $OPERATION == "plan" ]]; then
  FLAGS=""
fi

for region in $(ls $CHANNEL)
do
    # TODO - some validation here that _if_ the workspace already exists,
    # it is in a project that matches $APP_NAME
    rm -rf .terraform .terraform.lock.hcl
    # Workspace names must be unique across the entire organization,
    # So despite duplicated the APP_NAME in the project and here, it is
    # necessary
    TF_WORKSPACE="$APP_NAME-$PATTERN-$CHANNEL-$region"
    sed -i".bak" "s/__TF_WORKSPACE__/$TF_WORKSPACE/" backend.tf
    echo "Setting up workspace for $TF_WORKSPACE"
    terraform init -plugin-dir=./foo/bar || true #this command will "fail" but the cloud backend will be initialized

    # curl -s -H "Authorization: Bearer $TFE_TOKEN" -H "Content-Type: application/vnd.api+json" \
    #   -X PATCH -d @update-payload.json \
    #   "https://app.terraform.io/api/v2/organizations/$TF_CLOUD_ORGANIZATION/workspaces/$TF_WORKSPACE"

    terraform $OPERATION -var-file="$CHANNEL/$region/terraform.tfvars" $FLAGS
    if [[ $OPERATION == "destroy" ]]; then
      curl -s -H "Authorization: Bearer $TFE_TOKEN" -H "Content-Type: application/vnd.api+json" \
        -X POST \
        "https://$TF_HOSTNAME/api/v2/organizations/$TF_CLOUD_ORGANIZATION/workspaces/$TF_WORKSPACE/actions/safe-delete"
    fi
    cp -f backend.tf.bak backend.tf
done
