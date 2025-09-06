#!/bin/bash

# AWS E-Commerce Platform Deployment Script
# This script deploys the infrastructure using Terraform and sets up the application

set -e

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
PROJECT_NAME="aws-ecommerce"
ENVIRONMENT="production"
AWS_REGION="us-east-1"
TERRAFORM_DIR="./terraform"
APP_DIR="./application"

# Functions
log() {
    echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] $1${NC}"
}

warn() {
    echo -e "${YELLOW}[$(date +'%Y-%m-%d %H:%M:%S')] WARNING: $1${NC}"
}

error() {
    echo -e "${RED}[$(date +'%Y-%m-%d %H:%M:%S')] ERROR: $1${NC}"
    exit 1
}

info() {
    echo -e "${BLUE}[$(date +'%Y-%m-%d %H:%M:%S')] INFO: $1${NC}"
}

# Check prerequisites
check_prerequisites() {
    log "Checking prerequisites..."
    
    # Check if AWS CLI is installed and configured
    if ! command -v aws &> /dev/null; then
        error "AWS CLI is not installed. Please install it first."
    fi
    
    # Check AWS credentials
    if ! aws sts get-caller-identity &> /dev/null; then
        error "AWS credentials are not configured. Run 'aws configure' first."
    fi
    
    # Check if Terraform is installed
    if ! command -v terraform &> /dev/null; then
        error "Terraform is not installed. Please install it first."
    fi
    
    # Check if Docker is installed
    if ! command -v docker &> /dev/null; then
        warn "Docker is not installed. You'll need it for local testing."
    fi
    
    log "Prerequisites check completed successfully"
}

# Initialize Terraform
init_terraform() {
    log "Initializing Terraform..."
    
    cd "$TERRAFORM_DIR"
    
    # Initialize Terraform
    terraform init
    
    # Validate Terraform configuration
    terraform validate
    
    cd - > /dev/null
    
    log "Terraform initialized successfully"
}

# Plan Terraform deployment
plan_terraform() {
    log "Planning Terraform deployment..."
    
    cd "$TERRAFORM_DIR"
    
    # Generate Terraform plan
    terraform plan \
        -var="project_name=$PROJECT_NAME" \
        -var="environment=$ENVIRONMENT" \
        -var="aws_region=$AWS_REGION" \
        -out=tfplan
    
    cd - > /dev/null
    
    log "Terraform plan generated successfully"
}

# Apply Terraform configuration
apply_terraform() {
    log "Applying Terraform configuration..."
    
    cd "$TERRAFORM_DIR"
    
    # Apply Terraform plan
    terraform apply tfplan
    
    # Get outputs
    ALB_DNS_NAME=$(terraform output -raw alb_dns_name)
    RDS_ENDPOINT=$(terraform output -raw rds_endpoint)
    S3_BUCKET_NAME=$(terraform output -raw s3_bucket_name)
    
    cd - > /dev/null
    
    log "Infrastructure deployed successfully"
    info "Application Load Balancer DNS: $ALB_DNS_NAME"
    info "RDS Endpoint: $RDS_ENDPOINT"
    info "S3 Bucket: $S3_BUCKET_NAME"
}

# Create ECR repository
create_ecr_repo() {
    log "Creating ECR repository..."
    
    REPO_NAME="${PROJECT_NAME}-app"
    
    # Check if repository exists
    if ! aws ecr describe-repositories --repository-names $REPO_NAME --region $AWS_REGION &> /dev/null; then
        aws ecr create-repository \
            --repository-name $REPO_NAME \
            --region $AWS_REGION \
            --image-scanning-configuration scanOnPush=true \
            --encryption-configuration encryptionType=AES256
        
        log "ECR repository created: $REPO_NAME"
    else
        info "ECR repository already exists: $REPO_NAME"
    fi
    
    # Get repository URI
    REPO_URI=$(aws ecr describe-repositories \
        --repository-names $REPO_NAME \
        --region $AWS_REGION \
        --query 'repositories[0].repositoryUri' \
        --output text)
    
    log "ECR repository URI: $REPO_URI"
}

# Build and push Docker image
build_and_push_image() {
    log "Building and pushing Docker image..."
    
    cd "$APP_DIR"
    
    # Login to ECR
    aws ecr get-login-password --region $AWS_REGION | docker login --username AWS --password-stdin $REPO_URI
    
    # Build Docker image
    docker build -t $PROJECT_NAME-app .
    
    # Tag image for ECR
    docker tag $PROJECT_NAME-app:latest $REPO_URI:latest
    docker tag $PROJECT_NAME-app:latest $REPO_URI:v1.0.0
    
    # Push image to ECR
    docker push $REPO_URI:latest
    docker push $REPO_URI:v1.0.0
    
    cd - > /dev/null
    
    log "Docker image built and pushed successfully"
}

# Deploy application to EC2 instances
deploy_application() {
    log "Deploying application to EC2 instances..."
    
    # Get Auto Scaling Group name
    cd "$TERRAFORM_DIR"
    ASG_NAME=$(terraform output -raw asg_name)
    cd - > /dev/null
    
    # Create deployment script
    cat > /tmp/deploy_app.sh << EOF
#!/bin/bash
# Update system
sudo yum update -y

# Install Docker
sudo yum install -y docker
sudo systemctl start docker
sudo systemctl enable docker
sudo usermod -a -G docker ec2-user

# Install AWS CLI v2
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip awscliv2.zip
sudo ./aws/install

# Login to ECR and pull image
aws ecr get-login-password --region $AWS_REGION | docker login --username AWS --password-stdin $REPO_URI

# Pull and run the application
docker pull $REPO_URI:latest

# Stop any existing container
docker stop ecommerce-app 2>/dev/null || true
docker rm ecommerce-app 2>/dev/null || true

# Run the application
docker run -d \
    --name ecommerce-app \
    --restart always \
    -p 80:80 \
    -e DB_HOST="$RDS_ENDPOINT" \
    -e DB_NAME="ecommerce" \
    -e DB_USER="admin" \
    -e DB_PASSWORD="your-db-password" \
    -e S3_BUCKET="$S3_BUCKET_NAME" \
    -e AWS_REGION="$AWS_REGION" \
    $REPO_URI:latest

# Install CloudWatch agent
wget https://s3.amazonaws.com/amazoncloudwatch-agent/amazon_linux/amd64/latest/amazon-cloudwatch-agent.rpm
sudo rpm -U ./amazon-cloudwatch-agent.rpm
EOF
    
    # Upload deployment script to S3
    aws s3 cp /tmp/deploy_app.sh s3://$S3_BUCKET_NAME/scripts/deploy_app.sh
    
    # Create Systems Manager document for deployment
    aws ssm create-document \
        --name "${PROJECT_NAME}-deploy-app" \
        --document-type "Command" \
        --document-format JSON \
        --content '{
            "schemaVersion": "2.2",
            "description": "Deploy E-Commerce Application",
            "parameters": {},
            "mainSteps": [
                {
                    "action": "aws:runShellScript",
                    "name": "deployApp",
                    "inputs": {
                        "runCommand": [
                            "aws s3 cp s3://'$S3_BUCKET_NAME'/scripts/deploy_app.sh /tmp/deploy_app.sh",
                            "chmod +x /tmp/deploy_app.sh",
                            "/tmp/deploy_app.sh"
                        ]
                    }
                }
            ]
        }' \
        --region $AWS_REGION 2>/dev/null || info "SSM document already exists"
    
    # Execute deployment on all instances in ASG
    INSTANCE_IDS=$(aws autoscaling describe-auto-scaling-groups \
        --auto-scaling-group-names $ASG_NAME \
        --region $AWS_REGION \
        --query 'AutoScalingGroups[0].Instances[?LifecycleState==`InService`].InstanceId' \
        --output text)
    
    if [ -n "$INSTANCE_IDS" ]; then
        aws ssm send-command \
            --document-name "${PROJECT_NAME}-deploy-app" \
            --instance-ids $INSTANCE_IDS \
            --region $AWS_REGION
        
        log "Application deployment initiated on EC2 instances"
    else
        warn "No running instances found in Auto Scaling Group"
    fi
    
    # Clean up
    rm -f /tmp/deploy_app.sh
}

# Setup monitoring and alarms
setup_monitoring() {
    log "Setting up monitoring and alarms..."
    
    # Create SNS topic for alerts
    TOPIC_ARN=$(aws sns create-topic \
        --name "${PROJECT_NAME}-alerts" \
        --region $AWS_REGION \
        --query 'TopicArn' \
        --output text)
    
    # Subscribe email to SNS topic (replace with your email)
    # aws sns subscribe \