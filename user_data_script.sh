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
tar -czf $BACKUP_DIR/logs_$DATE.tar.gz /opt/ecommerce/logs/ 2>/dev/null || true

# Backup application uploads
tar -czf $BACKUP_DIR/uploads_$DATE.tar.gz /opt/ecommerce/uploads/ 2>/dev/null || true

# Upload to S3
aws s3 cp $BACKUP_DIR/logs_$DATE.tar.gz s3://$S3_BUCKET_BACKUP/logs/ || true
aws s3 cp $BACKUP_DIR/uploads_$DATE.tar.gz s3://$S3_BUCKET_BACKUP/uploads/ || true

# Clean up old local backups (keep last 3 days)
find $BACKUP_DIR -type f -mtime +3 -delete

echo "Backup completed: $DATE"
EOF

chmod +x /opt/ecommerce/backup.sh

# Create monitoring script
echo "Creating monitoring script..."
cat > /opt/ecommerce/monitor.sh << 'EOF'
#!/bin/bash

# Monitoring script to check application health
set -e

AWS_REGION=$(curl -s http://169.254.169.254/latest/meta-data/placement/region)
INSTANCE_ID=$(curl -s http://169.254.169.254/latest/meta-data/instance-id)

# Check application health
check_app_health() {
    if curl -f http://localhost:80/health > /dev/null 2>&1; then
        echo "Application is healthy"
        # Send success metric to CloudWatch
        aws cloudwatch put-metric-data \
            --namespace "ECommerce/Application" \
            --metric-data MetricName=HealthCheck,Value=1,Unit=Count,Dimensions=InstanceId=$INSTANCE_ID \
            --region $AWS_REGION
        return 0
    else
        echo "Application health check failed"
        # Send failure metric to CloudWatch
        aws cloudwatch put-metric-data \
            --namespace "ECommerce/Application" \
            --metric-data MetricName=HealthCheck,Value=0,Unit=Count,Dimensions=InstanceId=$INSTANCE_ID \
            --region $AWS_REGION
        return 1
    fi
}

# Check Docker container status
check_docker_status() {
    if docker ps | grep -q ecommerce-app; then
        echo "Docker container is running"
        return 0
    else
        echo "Docker container is not running"
        return 1
    fi
}

# Main monitoring logic
main() {
    echo "Running health checks at $(date)"
    
    if ! check_docker_status; then
        echo "Attempting to restart application..."
        /opt/ecommerce/deploy.sh
    fi
    
    if ! check_app_health; then
        echo "Application health check failed, attempting restart..."
        cd /opt/ecommerce
        docker-compose restart
        sleep 30
        check_app_health
    fi
    
    # Send system metrics
    DISK_USAGE=$(df -h / | awk 'NR==2 {print $5}' | sed 's/%//')
    MEMORY_USAGE=$(free | awk 'NR==2{printf "%.2f", $3*100/$2 }')
    
    aws cloudwatch put-metric-data \
        --namespace "ECommerce/System" \
        --metric-data MetricName=DiskUsage,Value=$DISK_USAGE,Unit=Percent,Dimensions=InstanceId=$INSTANCE_ID \
        --region $AWS_REGION
    
    aws cloudwatch put-metric-data \
        --namespace "ECommerce/System" \
        --metric-data MetricName=MemoryUsage,Value=$MEMORY_USAGE,Unit=Percent,Dimensions=InstanceId=$INSTANCE_ID \
        --region $AWS_REGION
}

main
EOF

chmod +x /opt/ecommerce/monitor.sh

# Set up cron jobs
echo "Setting up cron jobs..."
cat > /tmp/crontab << 'EOF'
# E-Commerce Application Cron Jobs

# Health check every 5 minutes
*/5 * * * * /opt/ecommerce/monitor.sh >> /opt/ecommerce/logs/monitor.log 2>&1

# Backup every day at 2 AM
0 2 * * * /opt/ecommerce/backup.sh >> /opt/ecommerce/logs/backup.log 2>&1

# Log rotation weekly
0 0 * * 0 find /opt/ecommerce/logs -name "*.log" -size +100M -delete

# Docker cleanup monthly
0 3 1 * * docker system prune -f >> /opt/ecommerce/logs/cleanup.log 2>&1
EOF

crontab /tmp/crontab
rm /tmp/crontab

# Create application health check endpoint test
echo "Creating health check test..."
cat > /opt/ecommerce/health_check.sh << 'EOF'
#!/bin/bash

# Simple health check script for load balancer
HEALTH_URL="http://localhost:80/health"
TIMEOUT=5

if curl -f --max-time $TIMEOUT "$HEALTH_URL" > /dev/null 2>&1; then
    echo "OK"
    exit 0
else
    echo "FAILED"
    exit 1
fi
EOF

chmod +x /opt/ecommerce/health_check.sh

# Install Docker Compose
echo "Installing Docker Compose..."
curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
chmod +x /usr/local/bin/docker-compose
ln -sf /usr/local/bin/docker-compose /usr/bin/docker-compose

# Configure log rotation
echo "Configuring log rotation..."
cat > /etc/logrotate.d/ecommerce << 'EOF'
/opt/ecommerce/logs/*.log {
    daily
    missingok
    rotate 7
    compress
    delaycompress
    notifempty
    copytruncate
}
EOF

# Set up system limits
echo "Configuring system limits..."
cat >> /etc/security/limits.conf << 'EOF'
# E-Commerce application limits
* soft nofile 65535
* hard nofile 65535
* soft nproc 4096
* hard nproc 4096
EOF

# Configure sysctl for better performance
echo "Configuring sysctl..."
cat >> /etc/sysctl.conf << 'EOF'
# E-Commerce application optimizations
net.core.somaxconn = 1024
net.ipv4.tcp_max_syn_backlog = 1024
net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.tcp_fin_timeout = 30
net.ipv4.tcp_keepalive_time = 1200
net.ipv4.tcp_syncookies = 1
vm.swappiness = 10
EOF

sysctl -p

# Create systemd service for the application
echo "Creating systemd service..."
cat > /etc/systemd/system/ecommerce.service << 'EOF'
[Unit]
Description=E-Commerce Application
Requires=docker.service
After=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=/opt/ecommerce
ExecStart=/opt/ecommerce/deploy.sh
ExecStop=/usr/local/bin/docker-compose down
TimeoutStartSec=0
User=root

[Install]
WantedBy=multi-user.target
EOF

# Enable the service
systemctl daemon-reload
systemctl enable ecommerce.service

# Create application user
echo "Creating application user..."
useradd -r -m -s /bin/bash ecommerce || true
usermod -a -G docker ecommerce
chown -R ecommerce:ecommerce /opt/ecommerce

# Set up log directory permissions
chmod 755 /opt/ecommerce/logs
chown ecommerce:ecommerce /opt/ecommerce/logs

# Install additional monitoring tools
echo "Installing additional monitoring tools..."
yum install -y \
    iotop \
    iftop \
    tcpdump \
    strace \
    lsof \
    nc

# Configure firewall (if iptables is available)
if command -v iptables &> /dev/null; then
    echo "Configuring basic firewall rules..."
    # Allow SSH (22), HTTP (80), and HTTPS (443)
    iptables -I INPUT -p tcp --dport 22 -j ACCEPT
    iptables -I INPUT -p tcp --dport 80 -j ACCEPT
    iptables -I INPUT -p tcp --dport 443 -j ACCEPT
    # Allow established connections
    iptables -I INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
    # Save rules (Amazon Linux 2)
    service iptables save 2>/dev/null || true
fi

# Create application status script
echo "Creating application status script..."
cat > /opt/ecommerce/status.sh << 'EOF'
#!/bin/bash

echo "=== E-Commerce Application Status ==="
echo "Date: $(date)"
echo "Instance ID: $(curl -s http://169.254.169.254/latest/meta-data/instance-id)"
echo "Region: $(curl -s http://169.254.169.254/latest/meta-data/placement/region)"
echo ""

echo "=== System Information ==="
echo "Uptime: $(uptime)"
echo "Memory: $(free -h | grep Mem)"
echo "Disk: $(df -h / | tail -1)"
echo ""

echo "=== Docker Status ==="
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
echo ""

echo "=== Application Health ==="
if curl -f http://localhost:80/health > /dev/null 2>&1; then
    echo "✓ Application is healthy"
else
    echo "✗ Application health check failed"
fi
echo ""

echo "=== Recent Logs ==="
tail -10 /opt/ecommerce/logs/monitor.log 2>/dev/null || echo "No monitor logs found"
EOF

chmod +x /opt/ecommerce/status.sh

# Set proper ownership
chown -R ecommerce:ecommerce /opt/ecommerce

# Signal successful completion
echo "User data script completed successfully at $(date)"

# Send completion metric to CloudWatch
aws cloudwatch put-metric-data \
    --namespace "ECommerce/Bootstrap" \
    --metric-data MetricName=UserDataCompletion,Value=1,Unit=Count,Dimensions=InstanceId=$INSTANCE_ID \
    --region $AWS_REGION || true

# Create completion marker
touch /opt/ecommerce/.bootstrap_complete

echo "Bootstrap process completed. Instance is ready for application deployment."