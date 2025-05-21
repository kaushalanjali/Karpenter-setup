#!/bin/bash
set -euo pipefail

# ----------------------
# Load Configuration
# ----------------------

CONFIG_FILE=$1

if [ ! -f "$CONFIG_FILE" ]; then
  echo "Config file not found: $CONFIG_FILE"
  exit 1
fi

# Source config file
source "$CONFIG_FILE"

# ----------------------
# Validate Required Variables
# ----------------------

REQUIRED_VARS=(
  KARPENTER_NAMESPACE
  CLUSTER_NAME
  AWS_PARTITION
  K8S_VERSION
)

for VAR in "${REQUIRED_VARS[@]}"; do
  if [ -z "${!VAR:-}" ]; then
    echo "Missing required variable: $VAR"
    exit 1
  fi
done

# ----------------------
# Derived Variables
# ----------------------

AWS_REGION=$(aws configure get region)
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query 'Account' --output text)
OIDC_ENDPOINT=$(aws eks describe-cluster --name "${CLUSTER_NAME}" --query "cluster.identity.oidc.issuer" --output text)

ARM_AMI_ID=$(aws ssm get-parameter --name "/aws/service/eks/optimized-ami/${K8S_VERSION}/amazon-linux-2-arm64/recommended/image_id" --query Parameter.Value --output text)
AMD_AMI_ID=$(aws ssm get-parameter --name "/aws/service/eks/optimized-ami/${K8S_VERSION}/amazon-linux-2/recommended/image_id" --query Parameter.Value --output text)
GPU_AMI_ID=$(aws ssm get-parameter --name "/aws/service/eks/optimized-ami/${K8S_VERSION}/amazon-linux-2-gpu/recommended/image_id" --query Parameter.Value --output text)

# ----------------------
# Trust Policies
# ----------------------

cat > node-trust-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "Service": "ec2.amazonaws.com" },
    "Action": "sts:AssumeRole"
  }]
}
EOF

cat > controller-trust-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {
      "Federated": "arn:${AWS_PARTITION}:iam::${AWS_ACCOUNT_ID}:oidc-provider/${OIDC_ENDPOINT#*//}"
    },
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {
      "StringEquals": {
        "${OIDC_ENDPOINT#*//}:aud": "sts.amazonaws.com",
        "${OIDC_ENDPOINT#*//}:sub": "system:serviceaccount:${KARPENTER_NAMESPACE}:karpenter"
      }
    }
  }]
}
EOF

# ----------------------
# Create Roles
# ----------------------

aws iam create-role   --role-name "KarpenterNodeRole-${CLUSTER_NAME}"   --assume-role-policy-document file://node-trust-policy.json || true

aws iam create-role   --role-name "KarpenterControllerRole-${CLUSTER_NAME}"   --assume-role-policy-document file://controller-trust-policy.json || true

# ----------------------
# Attach Node Role Policies
# ----------------------

for policy in AmazonEKSWorkerNodePolicy AmazonEKS_CNI_Policy AmazonEC2ContainerRegistryReadOnly AmazonSSMManagedInstanceCore; do
  aws iam attach-role-policy     --role-name "KarpenterNodeRole-${CLUSTER_NAME}"     --policy-arn "arn:${AWS_PARTITION}:iam::aws:policy/${policy}" || true
done

# ----------------------
# Tag Subnets for Karpenter Discovery
# ----------------------

echo "Tagging subnets with karpenter.sh/discovery=${CLUSTER_NAME}..."
for NODEGROUP in $(aws eks list-nodegroups --cluster-name "${CLUSTER_NAME}" --query 'nodegroups' --output text); do
  SUBNETS=$(aws eks describe-nodegroup --cluster-name "${CLUSTER_NAME}" --nodegroup-name "${NODEGROUP}" --query 'nodegroup.subnets' --output text)
  aws ec2 create-tags --tags "Key=karpenter.sh/discovery,Value=${CLUSTER_NAME}" --resources ${SUBNETS}
done

# ----------------------
# Tag Security Groups for Karpenter Discovery
# ----------------------

echo "Tagging security groups with karpenter.sh/discovery=${CLUSTER_NAME}..."

NODEGROUP=$(aws eks list-nodegroups --cluster-name "${CLUSTER_NAME}" --query 'nodegroups[0]' --output text)
LAUNCH_TEMPLATE=$(aws eks describe-nodegroup --cluster-name "${CLUSTER_NAME}" --nodegroup-name "${NODEGROUP}" --query 'nodegroup.launchTemplate.{id:id,version:version}' --output text | tr -s "\t" ",")

CLUSTER_SG=$(aws eks describe-cluster --name "${CLUSTER_NAME}" --query "cluster.resourcesVpcConfig.clusterSecurityGroupId" --output text)
TEMPLATE_SGS=$(aws ec2 describe-launch-template-versions --launch-template-id "${LAUNCH_TEMPLATE%,*}" --versions "${LAUNCH_TEMPLATE#*,}" --query 'LaunchTemplateVersions[0].LaunchTemplateData.NetworkInterfaces[0].Groups' --output text 2>/dev/null || echo "")

SECURITY_GROUPS="${CLUSTER_SG} ${TEMPLATE_SGS}"

aws ec2 create-tags --tags "Key=karpenter.sh/discovery,Value=${CLUSTER_NAME}" --resources ${SECURITY_GROUPS}


# ----------------------
# Controller Role Policy
# ----------------------

cat > controller-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "KarpenterCoreActions",
      "Effect": "Allow",
      "Action": [
        "ssm:GetParameter", "ec2:Describe*", "ec2:RunInstances", "ec2:CreateTags",
        "ec2:CreateLaunchTemplate", "ec2:CreateFleet", "ec2:DeleteLaunchTemplate",
        "pricing:GetProducts"
      ],
      "Resource": "*"
    },
    {
      "Sid": "ConditionalEC2Termination",
      "Effect": "Allow",
      "Action": "ec2:TerminateInstances",
      "Resource": "*",
      "Condition": {
        "StringLike": {
          "ec2:ResourceTag/karpenter.sh/nodepool": "*"
        }
      }
    },
    {
      "Sid": "PassNodeIAMRole",
      "Effect": "Allow",
      "Action": "iam:PassRole",
      "Resource": "arn:${AWS_PARTITION}:iam::${AWS_ACCOUNT_ID}:role/KarpenterNodeRole-${CLUSTER_NAME}"
    },
    {
      "Sid": "EKSClusterEndpointLookup",
      "Effect": "Allow",
      "Action": "eks:DescribeCluster",
      "Resource": "arn:${AWS_PARTITION}:eks:${AWS_REGION}:${AWS_ACCOUNT_ID}:cluster/${CLUSTER_NAME}"
    },
    {
      "Sid": "InstanceProfileScopedActions",
      "Effect": "Allow",
      "Action": [
        "iam:CreateInstanceProfile", "iam:AddRoleToInstanceProfile",
        "iam:RemoveRoleFromInstanceProfile", "iam:DeleteInstanceProfile",
        "iam:TagInstanceProfile", "iam:GetInstanceProfile"
      ],
      "Resource": "*",
      "Condition": {
        "StringEquals": {
          "aws:ResourceTag/kubernetes.io/cluster/${CLUSTER_NAME}": "owned",
          "aws:ResourceTag/topology.kubernetes.io/region": "${AWS_REGION}"
        },
        "StringLike": {
          "aws:ResourceTag/karpenter.k8s.aws/ec2nodeclass": "*"
        }
      }
    }
  ]
}
EOF

aws iam put-role-policy   --role-name "KarpenterControllerRole-${CLUSTER_NAME}"   --policy-name "KarpenterControllerPolicy-${CLUSTER_NAME}"   --policy-document file://controller-policy.json || true


# ----------------------
# Tag Subnets for Karpenter Discovery
# ----------------------

echo "Tagging subnets with karpenter.sh/discovery=${CLUSTER_NAME}..."
for NODEGROUP in $(aws eks list-nodegroups --cluster-name "${CLUSTER_NAME}" --query 'nodegroups' --output text); do
  SUBNETS=$(aws eks describe-nodegroup --cluster-name "${CLUSTER_NAME}" --nodegroup-name "${NODEGROUP}" --query 'nodegroup.subnets' --output text)
  aws ec2 create-tags --tags "Key=karpenter.sh/discovery,Value=${CLUSTER_NAME}" --resources ${SUBNETS}
done

# ----------------------
# Tag Security Groups for Karpenter Discovery
# ----------------------

echo "Tagging security groups with karpenter.sh/discovery=${CLUSTER_NAME}..."

NODEGROUP=$(aws eks list-nodegroups --cluster-name "${CLUSTER_NAME}" --query 'nodegroups[0]' --output text)
LAUNCH_TEMPLATE=$(aws eks describe-nodegroup --cluster-name "${CLUSTER_NAME}" --nodegroup-name "${NODEGROUP}" --query 'nodegroup.launchTemplate.{id:id,version:version}' --output text | tr -s "\t" ",")

# Retrieve security groups - both cluster SG and launch template SG (if applicable)
CLUSTER_SG=$(aws eks describe-cluster --name "${CLUSTER_NAME}" --query "cluster.resourcesVpcConfig.clusterSecurityGroupId" --output text)
TEMPLATE_SGS=$(aws ec2 describe-launch-template-versions --launch-template-id "${LAUNCH_TEMPLATE%,*}" --versions "${LAUNCH_TEMPLATE#*,}" --query 'LaunchTemplateVersions[0].LaunchTemplateData.NetworkInterfaces[0].Groups' --output text 2>/dev/null || echo "")

SECURITY_GROUPS="${CLUSTER_SG} ${TEMPLATE_SGS}"

aws ec2 create-tags --tags "Key=karpenter.sh/discovery,Value=${CLUSTER_NAME}" --resources ${SECURITY_GROUPS}
