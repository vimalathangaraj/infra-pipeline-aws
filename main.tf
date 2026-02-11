name: Infra + Deploy (EKS/ECR/S3/EC2)

on:
  push:
    branches: ["main"]

permissions:
  contents: read
  id-token: write

env:
  AWS_REGION: eu-north-1
  TF_VERSION: 1.6.6

jobs:
  infra:
    runs-on: ubuntu-latest

    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Configure AWS (OIDC)
        uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: ${{ secrets.AWS_ROLE_ARN }}
          aws-region: ${{ env.AWS_REGION }}

      - name: Setup Terraform
        uses: hashicorp/setup-terraform@v3
        with:
          terraform_version: ${{ env.TF_VERSION }}

      - name: Detect Terraform directory
        id: tfdir
        run: |
          set -e
          TF_DIR=$(find . -maxdepth 6 -type f -name "*.tf" -print | head -n 1 | xargs -I{} dirname "{}")
          if [ -z "$TF_DIR" ]; then
            echo "ERROR: No *.tf files found in repo (depth 6)."
            exit 1
          fi
          TF_DIR="${TF_DIR#./}"
          echo "TF_DIR=$TF_DIR" >> "$GITHUB_OUTPUT"
          echo "Using TF_DIR=$TF_DIR"
          ls -la "$TF_DIR"

      - name: Terraform init
        run: |
          set -e
          cd "${{ steps.tfdir.outputs.TF_DIR }}"
          terraform init -input=false

      # ✅ FIX for RepositoryAlreadyExists / LogGroupAlreadyExists / KMS alias already exists
      - name: Import existing AWS resources (only if missing in state)
        run: |
          set -e
          cd "${{ steps.tfdir.outputs.TF_DIR }}"

          NAME_PREFIX="ci-eks"                 # must match your -var name_prefix
          ECR_NAME="${NAME_PREFIX}-app"        # matches aws_ecr_repository.app name in your TF
          CLUSTER_NAME="${NAME_PREFIX}-eks"    # matches module.eks.cluster_name in your TF
          LOG_GROUP="/aws/eks/${CLUSTER_NAME}/cluster"
          KMS_ALIAS="alias/eks/${CLUSTER_NAME}"

          echo "ECR_NAME=$ECR_NAME"
          echo "CLUSTER_NAME=$CLUSTER_NAME"
          echo "LOG_GROUP=$LOG_GROUP"
          echo "KMS_ALIAS=$KMS_ALIAS"

          # ECR
          terraform state show aws_ecr_repository.app >/dev/null 2>&1 || \
            (echo "Importing ECR..." && terraform import aws_ecr_repository.app "$ECR_NAME") || true

          # CloudWatch Log Group (created by EKS module)
          terraform state show 'module.eks.aws_cloudwatch_log_group.this[0]' >/dev/null 2>&1 || \
            (echo "Importing Log Group..." && terraform import 'module.eks.aws_cloudwatch_log_group.this[0]' "$LOG_GROUP") || true

          # KMS Alias (created inside module.eks.module.kms)
          terraform state show 'module.eks.module.kms.aws_kms_alias.this["cluster"]' >/dev/null 2>&1 || \
            (echo "Importing KMS Alias..." && terraform import 'module.eks.module.kms.aws_kms_alias.this["cluster"]' "$KMS_ALIAS") || true

      - name: Terraform validate
        run: |
          set -e
          cd "${{ steps.tfdir.outputs.TF_DIR }}"
          terraform validate

      - name: Terraform apply
        run: |
          set -e
          cd "${{ steps.tfdir.outputs.TF_DIR }}"
          terraform apply -auto-approve \
            -var="aws_region=${{ env.AWS_REGION }}" \
            -var="name_prefix=ci-eks" \
            -var="app_bucket_name=ci-eks-app-bucket-149916142098" \
            -var="ec2_ami_id=ami-04233b5aecce09244"

      - name: Export Terraform outputs
        run: |
          set -e
          cd "${{ steps.tfdir.outputs.TF_DIR }}"
          terraform output -json > "${GITHUB_WORKSPACE}/outputs.json"
          ls -la "${GITHUB_WORKSPACE}/outputs.json"

      - name: Upload outputs
        uses: actions/upload-artifact@v4
        with:
          name: tf-outputs
          path: outputs.json

  deploy:
    runs-on: ubuntu-latest
    needs: infra

    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Configure AWS (OIDC)
        uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: ${{ secrets.AWS_ROLE_ARN }}
          aws-region: ${{ env.AWS_REGION }}

      - name: Download outputs
        uses: actions/download-artifact@v4
        with:
          name: tf-outputs
          path: .

      - name: Install jq
        run: |
          sudo apt-get update
          sudo apt-get install -y jq

      - name: Read outputs
        id: out
        run: |
          set -e
          test -f outputs.json
          echo "ECR_REPO_URL=$(jq -r .ecr_repo_url.value outputs.json)" >> $GITHUB_OUTPUT
          echo "CLUSTER_NAME=$(jq -r .cluster_name.value outputs.json)" >> $GITHUB_OUTPUT

      - name: Login to ECR
        uses: aws-actions/amazon-ecr-login@v2

      - name: Build and push image
        id: img
        run: |
          set -e
          IMAGE="${{ steps.out.outputs.ECR_REPO_URL }}:${{ github.sha }}"
          docker build -t "$IMAGE" app
          docker push "$IMAGE"
          echo "IMAGE=$IMAGE" >> $GITHUB_OUTPUT

      - name: Setup kubectl
        uses: azure/setup-kubectl@v4
        with:
          version: "v1.29.0"

      - name: Update kubeconfig
        run: |
          set -e
          aws eks update-kubeconfig \
            --region "${{ env.AWS_REGION }}" \
            --name "${{ steps.out.outputs.CLUSTER_NAME }}"

      - name: Deploy to EKS
        run: |
          set -e
          sed -i "s|REPLACE_IMAGE|${{ steps.img.outputs.IMAGE }}|g" app/k8s/deployment.yaml
          kubectl apply -f app/k8s/deployment.yaml
          kubectl apply -f app/k8s/service.yaml
          kubectl rollout status deployment/web
