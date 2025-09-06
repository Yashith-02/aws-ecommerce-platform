#!/bin/bash

# User Data Script for AWS E-Commerce Platform EC2 Instances
# This script sets up the application environment on EC2 instances

# Set up logging
exec > >(tee /var/log/user-data.log|logger -t user-data -s 2>/dev/console) 2>&1
echo "Starting user data script execution at $(date)"

# Configuration variables (will be replaced by Terraform)
DB_ENDPOINT="${db_endpoint}"
S3_BUCKET="${s3_bucket}"
AWS_REGION="$(curl -s http://169.254.169.254/latest/meta-data/placement/region)"
INSTANCE_ID="$(curl -s http://169.254.169.254/latest/meta-data/instance-id)"

# Update system packages
echo "Updating system packages..."
yum update -y

# Install required packages
echo "Installing required packages..."
yum install -y \
    docker \
    amazon-cloudwatch-agent \
    amazon-ssm-agent \
    htop \
    git \
    unzip \
    curl \
    wget

# Install AWS CLI v2
echo "Installing AWS CLI v2..."
cd /tmp
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip awscliv2.zip
./aws/install
rm -rf aws awscliv2.zip

# Start and enable services
echo "Starting services..."
systemctl start docker
systemctl enable docker
systemctl start amazon-ssm-agent
systemctl enable amazon-ssm-agent

# Add ec2-user to docker group
usermod -a -G docker ec2-user

# Create application directories
echo "Creating application directories..."
mkdir -p /opt/ecommerce/{logs,uploads,backups}
chmod 755 /opt/ecommerce
chmod 777 /opt/ecommerce/{logs,uploads}

# Configure CloudWatch agent
echo "Configuring CloudWatch agent..."
cat > /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json << 'EOF'
{
    "agent": {
        "metrics_collection_interval": 60,
        "run_as_user": "cwagent"
    },
    "logs": {
        "logs_collected": {
            "files": {
                "collect_list": [
                    {
                        "file_path": "/var/log/user-data.log",
                        "log_group_name": "/aws/ec2/ecommerce/user-data",
                        "log_stream_name": "{instance_id}",
                        "timestamp_format": "%Y-%m-%d %H:%M:%S"
                    },
                    {
                        "file_path": "/var/log/docker",
                        "log_group_name": "/aws/ec2/ecommerce/docker",
                        "log_stream_name": "{instance_id}",
                        "timestamp_format": "%Y-%m-%dT%H:%M:%S.%f"
                    },
                    {
                        "file_path": "/opt/ecommerce/logs/app.log",
                        "log_group_name": "/aws/ec2/ecommerce/application",
                        "log_stream_name": "{instance_id}",
                        "timestamp_format": "%Y-%m-%d %H:%M:%S"
                    }
                ]
            }
        }
    },
    "metrics": {
        "namespace": "ECommerce/EC2",
        "metrics_collected": {
            "cpu": {
                "measurement": [
                    "cpu_usage_idle",
                    "cpu_usage_iowait",
                    "cpu_usage_user",
                    "cpu_usage_system"
                ],
                "metrics_collection_interval": 60,
                "totalcpu": false
            },
            "disk": {
                "measurement": [
                    "used_percent"
                ],
                "metrics_collection_interval": 60,
                "resources": [
                    "*"
                ]
            },
            "diskio": {
                "measurement": [
                    "io_time"
                ],
                "metrics_collection_interval": 60,
                "resources": [
                    "*"
                ]
            },
            "mem": {
                "measurement": [
                    "mem_used_percent"
                ],
                "metrics_collection_interval": 60
            },
            "netstat": {
                "measurement": [
                    "tcp_established",
                    "tcp_time_wait"
                ],
                "metrics_collection_interval": 60
            },
            "swap": {
                "measurement": [
                    "swap_used_percent"
                ],
                "metrics_collection_interval": 60
            }
        }
    }
}
EOF

# Start CloudWatch agent
/opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl \
    -a fetch-config \
    -m ec2 \
    -s \
    -c file:/opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json

# Create Docker Compose file for the application
echo "Creating Docker Compose configuration..."
cat > /opt/ecommerce/docker-compose.yml << EOF
version: '3.8'
services:
  ecommerce-app:
    image: \${ECR_URI}:latest
    container_name: ecommerce-app
    restart: unless-stopped
    ports:
      - "80:80"
    environment:
      - DB_HOST=${DB_ENDPOINT}
      - DB_NAME=ecommerce
      - DB_USER=admin
      - DB_PASSWORD=\${DB_PASSWORD}
      - S3_BUCKET=${S3_BUCKET}
      - AWS_REGION=${AWS_REGION}
      - FLASK_ENV=production
    volumes:
      - /opt/ecommerce/logs:/app/logs
      - /opt/ecommerce/uploads:/app/uploads
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:80/health"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 40s
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"
EOF

# Create deployment script
echo "Creating deployment script..."
cat > /opt/ecommerce/deploy.sh << 'EOF'
#!/bin/bash

# Deployment script for e-commerce application
set -e

# Configuration
ECR_REPOSITORY="aws-ecommerce-app"
AWS_REGION=$(curl -s http://169.254.169.254/latest/meta-data/placement/region)
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
ECR_URI="${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/${ECR_REPOSITORY}"

# Get database password from Parameter Store
DB_PASSWORD=$(aws ssm get-parameter --name "/ecommerce/db/password" --with-decryption --query 'Parameter.Value' --output text 2>/dev/null || echo "defaultpassword")

# Export environment variables
export ECR_URI
export DB_PASSWORD

echo "Logging into ECR..."
aws ecr get-login-password --region $AWS_REGION | docker login --username AWS --password-stdin $ECR_URI

echo "Pulling latest application image..."
docker pull $ECR_URI:latest

echo "Stopping existing containers..."
cd /opt/ecommerce
docker-compose down || true

echo "Starting new containers..."
docker-compose up -d

echo "Waiting for application to be ready..."
sleep 30

# Health check
for i in {1..10}; do
    if curl -f http://localhost:80/health > /dev/null 2>&1; then
        echo "Application is healthy"
        break
    else
        echo "Attempt $i: Application not ready yet, waiting..."
        sleep 10
    fi
done

# Clean up old images
echo "Cleaning up old Docker images..."
docker image prune -f

echo "Deployment completed successfully"
EOF

chmod +x /opt/ecommerce/deploy.sh

# Create backup script
echo "Creating backup script..."
cat > /opt/ecommerce/backup.sh << 'EOF'
#!/bin/bash

# Backup script for application logs and data
set -e

DATE=$(date +%Y%m%d_%H%M%S)
BACKUP_DIR="/opt/ecommerce/backups"
S3_BUCKET_BACKUP="${S3_BUCKET}/backups"

# Create backup directory
mkdir -p $BACKUP_DIR

# Backup logs
tar -cz