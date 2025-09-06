#!/usr/bin/env python3
"""
AWS E-Commerce Platform
A scalable e-commerce application built for AWS infrastructure
"""

from flask import Flask, render_template, request, jsonify, redirect, url_for, session
import os
import boto3
import mysql.connector
from mysql.connector import Error
import logging
import json
from datetime import datetime
from werkzeug.security import generate_password_hash, check_password_hash
from werkzeug.utils import secure_filename
import uuid

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)

# Initialize Flask app
app = Flask(__name__)
app.secret_key = os.environ.get('SECRET_KEY', 'default-secret-key-change-in-production')

# Configuration
class Config:
    DB_HOST = os.environ.get('DB_HOST', 'localhost')
    DB_NAME = os.environ.get('DB_NAME', 'ecommerce')
    DB_USER = os.environ.get('DB_USER', 'admin')
    DB_PASSWORD = os.environ.get('DB_PASSWORD', 'password')
    S3_BUCKET = os.environ.get('S3_BUCKET', 'ecommerce-bucket')
    AWS_REGION = os.environ.get('AWS_REGION', 'us-east-1')
    CLOUDFRONT_DOMAIN = os.environ.get('CLOUDFRONT_DOMAIN', '')

# Initialize AWS services
s3_client = boto3.client('s3', region_name=Config.AWS_REGION)
cloudwatch = boto3.client('cloudwatch', region_name=Config.AWS_REGION)

class DatabaseManager:
    """Database connection and operations manager"""
    
    def __init__(self):
        self.connection = None
    
    def connect(self):
        """Establish database connection"""
        try:
            self.connection = mysql.connector.connect(
                host=Config.DB_HOST,
                database=Config.DB_NAME,
                user=Config.DB_USER,
                password=Config.DB_PASSWORD,
                autocommit=True,
                pool_name='ecommerce_pool',
                pool_size=10
            )
            logger.info("Database connection established successfully")
            return True
        except Error as e:
            logger.error(f"Error connecting to database: {e}")
            return False
    
    def execute_query(self, query, params=None):
        """Execute a database query"""
        try:
            cursor = self.connection.cursor(dictionary=True)
            cursor.execute(query, params or ())
            if query.strip().upper().startswith('SELECT'):
                result = cursor.fetchall()
            else:
                result = cursor.rowcount
            cursor.close()
            return result
        except Error as e:
            logger.error(f"Database query error: {e}")
            return None
    
    def close(self):
        """Close database connection"""
        if self.connection and self.connection.is_connected():
            self.connection.close()
            logger.info("Database connection closed")

# Initialize database manager
db = DatabaseManager()

class MetricsManager:
    """CloudWatch metrics manager"""
    
    @staticmethod
    def put_custom_metric(metric_name, value, unit='Count'):
        """Send custom metrics to CloudWatch"""
        try:
            cloudwatch.put_metric_data(
                Namespace='ECommerce/Application',
                MetricData=[
                    {
                        'MetricName': metric_name,
                        'Value': value,
                        'Unit': unit,
                        'Timestamp': datetime.utcnow()
                    }
                ]
            )
        except Exception as e:
            logger.error(f"Error sending metric to CloudWatch: {e}")

class S3Manager:
    """S3 file upload and management"""
    
    @staticmethod
    def upload_file(file, folder='products'):
        """Upload file to S3 bucket"""
        try:
            filename = secure_filename(file.filename)
            key = f"{folder}/{uuid.uuid4()}_{filename}"
            
            s3_client.upload_fileobj(
                file,
                Config.S3_BUCKET,
                key,
                ExtraArgs={'ContentType': file.content_type}
            )
            
            if Config.CLOUDFRONT_DOMAIN:
                url = f"https://{Config.CLOUDFRONT_DOMAIN}/{key}"
            else:
                url = f"https://{Config.S3_BUCKET}.s3.{Config.AWS_REGION}.amazonaws.com/{key}"
            
            return url
        except Exception as e:
            logger.error(f"Error uploading file to S3: {e}")
            return None

# Routes
@app.route('/')
def index():
    """Home page with featured products"""
    try:
        # Get featured products
        products = db.execute_query("""
            SELECT id, name, price, description, image_url 
            FROM products 
            WHERE featured = 1 
            ORDER BY created_at DESC 
            LIMIT 8
        """)
        
        # Send page view metric
        MetricsManager.put_custom_metric('PageViews', 1)
        
        return render_template('index.html', products=products or [])
    except Exception as e:
        logger.error(f"Error loading home page: {e}")
        return render_template('error.html', message="Unable to load products"), 500

@app.route('/health')
def health_check():
    """Health check endpoint for load balancer"""
    try:
        # Check database connection
        if not db.connection or not db.connection.is_connected():
            db.connect()
        
        # Simple query to verify database
        result = db.execute_query("SELECT 1")
        
        if result is not None:
            return jsonify({
                'status': 'healthy',
                'timestamp': datetime.utcnow().isoformat(),
                'database': 'connected'
            }), 200
        else:
            return jsonify({
                'status': 'unhealthy',
                'database': 'disconnected'
            }), 503
            
    except Exception as e:
        logger.error(f"Health check failed: {e}")
        return jsonify({
            'status': 'unhealthy',
            'error': str(e)
        }), 503

@app.route('/products')
def products():
    """Products listing page"""
    try:
        page = int(request.args.get('page', 1))
        per_page = 12
        offset = (page - 1) * per_page
        
        # Get products with pagination
        products = db.execute_query("""
            SELECT id, name, price, description, image_url, category
            FROM products 
            WHERE active = 1
            ORDER BY created_at DESC 
            LIMIT %s OFFSET %s
        """, (per_page, offset))
        
        # Get total count for pagination
        total_count = db.execute_query("SELECT COUNT(*) as count FROM products WHERE active = 1")
        total = total_count[0]['count'] if total_count else 0
        
        # Send metric
        MetricsManager.put_custom_metric('ProductPageViews', 1)
        
        return render_template('products.html', 
                             products=products or [], 
                             page=page, 
                             total=total,
                             per_page=per_page)
    except Exception as e:
        logger.error(f"Error loading products: {e}")
        return render_template('error.html', message="Unable to load products"), 500

@app.route('/product/<int:product_id>')
def product_detail(product_id):
    """Individual product detail page"""
    try:
        product = db.execute_query("""
            SELECT id, name, price, description, image_url, category, stock_quantity
            FROM products 
            WHERE id = %s AND active = 1
        """, (product_id,))
        
        if not product:
            return render_template('error.html', message="Product not found"), 404
        
        # Get related products
        related = db.execute_query("""
            SELECT id, name, price, image_url
            FROM products 
            WHERE category = %s AND id != %s AND active = 1
            LIMIT 4
        """, (product[0]['category'], product_id))
        
        # Send metric
        MetricsManager.put_custom_metric('ProductDetailViews', 1)
        
        return render_template('product_detail.html', 
                             product=product[0], 
                             related_products=related or [])
    except Exception as e:
        logger.error(f"Error loading product detail: {e}")
        return render_template('error.html', message="Unable to load product"), 500

@app.route('/cart')
def cart():
    """Shopping cart page"""
    try:
        cart_items = session.get('cart', [])
        total = 0
        
        if cart_items:
            # Get product details for cart items
            product_ids = [item['id'] for item in cart_items]
            placeholders = ','.join(['%s'] * len(product_ids))
            
            products = db.execute_query(f"""
                SELECT id, name, price, image_url
                FROM products 
                WHERE id IN ({placeholders})
            """, product_ids)
            
            # Calculate total
            product_dict = {p['id']: p for p in products}
            for item in cart_items:
                if item['id'] in product_dict:
                    item['product'] = product_dict[item['id']]
                    item['subtotal'] = item['quantity'] * product_dict[item['id']]['price']
                    total += item['subtotal']
        
        return render_template('cart.html', cart_items=cart_items, total=total)
    except Exception as e:
        logger.error(f"Error loading cart: {e}")
        return render_template('error.html', message="Unable to load cart"), 500

@app.route('/add_to_cart', methods=['POST'])
def add_to_cart():
    """Add product to cart"""
    try:
        product_id = int(request.form.get('product_id'))
        quantity = int(request.form.get('quantity', 1))
        
        # Verify product exists and is in stock
        product = db.execute_query("""
            SELECT id, name, stock_quantity 
            FROM products 
            WHERE id = %s AND active = 1
        """, (product_id,))
        
        if not product:
            return jsonify({'error': 'Product not found'}), 404
        
        if product[0]['stock_quantity'] < quantity:
            return jsonify({'error': 'Insufficient stock'}), 400
        
        # Add to session cart
        cart = session.get('cart', [])
        
        # Check if product already in cart
        for item in cart:
            if item['id'] == product_id:
                item['quantity'] += quantity
                break
        else:
            cart.append({'id': product_id, 'quantity': quantity})
        
        session['cart'] = cart
        
        # Send metric
        MetricsManager.put_custom_metric('AddToCart', 1)
        
        return jsonify({'success': True, 'cart_count': len(cart)})
    except Exception as e:
        logger.error(f"Error adding to cart: {e}")
        return jsonify({'error': 'Unable to add to cart'}), 500

@app.route('/checkout', methods=['GET', 'POST'])
def checkout():
    """Checkout process"""
    if request.method == 'GET':
        cart_items = session.get('cart', [])
        if not cart_items:
            return redirect(url_for('cart'))
        
        return render_template('checkout.html')
    
    try:
        # Process checkout
        customer_data = {
            'name': request.form.get('name'),
            'email': request.form.get('email'),
            'address': request.form.get('address'),
            'phone': request.form.get('phone')
        }
        
        cart_items = session.get('cart', [])
        if not cart_items:
            return redirect(url_for('cart'))
        
        # Create order in database
        order_id = str(uuid.uuid4())
        
        # Insert order
        db.execute_query("""
            INSERT INTO orders (id, customer_name, customer_email, customer_address, 
                              customer_phone, status, created_at)
            VALUES (%s, %s, %s, %s, %s, 'pending', %s)
        """, (order_id, customer_data['name'], customer_data['email'], 
              customer_data['address'], customer_data['phone'], datetime.utcnow()))
        
        # Insert order items
        for item in cart_items:
            db.execute_query("""
                INSERT INTO order_items (order_id, product_id, quantity, created_at)
                VALUES (%s, %s, %s, %s)
            """, (order_id, item['id'], item['quantity'], datetime.utcnow()))
        
        # Clear cart
        session['cart'] = []
        
        # Send metrics
        MetricsManager.put_custom_metric('Orders', 1)
        MetricsManager.put_custom_metric('OrderValue', sum(item['quantity'] for item in cart_items), 'Count')
        
        return render_template('order_success.html', order_id=order_id)
        
    except Exception as e:
        logger.error(f"Error processing checkout: {e}")
        return render_template('error.html', message="Unable to process order"), 500

@app.route('/admin/upload', methods=['GET', 'POST'])
def admin_upload():
    """Admin product upload (simplified)"""
    if request.method == 'GET':
        return render_template('admin_upload.html')
    
    try:
        # Upload product image to S3
        if 'image' not in request.files:
            return jsonify({'error': 'No image file'}), 400
        
        file = request.files['image']
        if file.filename == '':
            return jsonify({'error': 'No file selected'}), 400
        
        # Upload to S3
        image_url = S3Manager.upload_file(file)
        if not image_url:
            return jsonify({'error': 'Failed to upload image'}), 500
        
        # Insert product into database
        product_data = {
            'name': request.form.get('name'),
            'description': request.form.get('description'),
            'price': float(request.form.get('price')),
            'category': request.form.get('category'),
            'stock_quantity': int(request.form.get('stock_quantity', 0)),
            'image_url': image_url
        }
        
        db.execute_query("""
            INSERT INTO products (name, description, price, category, stock_quantity, 
                                image_url, active, featured, created_at)
            VALUES (%s, %s, %s, %s, %s, %s, 1, 0, %s)
        """, (product_data['name'], product_data['description'], product_data['price'],
              product_data['category'], product_data['stock_quantity'], 
              product_data['image_url'], datetime.utcnow()))
        
        return jsonify({'success': True, 'message': 'Product uploaded successfully'})
        
    except Exception as e:
        logger.error(f"Error uploading product: {e}")
        return jsonify({'error': 'Failed to upload product'}), 500

@app.route('/api/metrics')
def api_metrics():
    """API endpoint for application metrics"""
    try:
        metrics = {
            'timestamp': datetime.utcnow().isoformat(),
            'database_status': 'connected' if db.connection and db.connection.is_connected() else 'disconnected',
            'total_products': 0,
            'total_orders': 0
        }
        
        # Get product count
        product_count = db.execute_query("SELECT COUNT(*) as count FROM products WHERE active = 1")
        if product_count:
            metrics['total_products'] = product_count[0]['count']
        
        # Get order count
        order_count = db.execute_query("SELECT COUNT(*) as count FROM orders")
        if order_count:
            metrics['total_orders'] = order_count[0]['count']
        
        return jsonify(metrics)
    except Exception as e:
        logger.error(f"Error getting metrics: {e}")
        return jsonify({'error': 'Unable to fetch metrics'}), 500

@app.errorhandler(404)
def not_found(error):
    """404 error handler"""
    return render_template('error.html', message="Page not found"), 404

@app.errorhandler(500)
def server_error(error):
    """500 error handler"""
    return render_template('error.html', message="Internal server error"), 500

def init_database():
    """Initialize database tables"""
    try:
        db.connect()
        
        # Create tables if they don't exist
        tables = [
            """
            CREATE TABLE IF NOT EXISTS products (
                id INT AUTO_INCREMENT PRIMARY KEY,
                name VARCHAR(255) NOT NULL,
                description TEXT,
                price DECIMAL(10,2) NOT NULL,
                category VARCHAR(100),
                stock_quantity INT DEFAULT 0,
                image_url VARCHAR(500),
                active BOOLEAN DEFAULT TRUE,
                featured BOOLEAN DEFAULT FALSE,
                created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
            )
            """,
            """
            CREATE TABLE IF NOT EXISTS orders (
                id VARCHAR(36) PRIMARY KEY,
                customer_name VARCHAR(255) NOT NULL,
                customer_email VARCHAR(255) NOT NULL,
                customer_address TEXT,
                customer_phone VARCHAR(20),
                status VARCHAR(50) DEFAULT 'pending',
                created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
            )
            """,
            """
            CREATE TABLE IF NOT EXISTS order_items (
                id INT AUTO_INCREMENT PRIMARY KEY,
                order_id VARCHAR(36),
                product_id INT,
                quantity INT NOT NULL,
                created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                FOREIGN KEY (order_id) REFERENCES orders(id),
                FOREIGN KEY (product_id) REFERENCES products(id)
            )
            """
        ]
        
        for table_sql in tables:
            db.execute_query(table_sql)
        
        logger.info("Database initialized successfully")
        
    except Exception as e:
        logger.error(f"Error initializing database: {e}")

if __name__ == '__main__':
    # Initialize database on startup
    init_database()
    
    # Start the application
    app.run(
        host='0.0.0.0',
        port=int(os.environ.get('PORT', 80)),
        debug=os.environ.get('FLASK_ENV') == 'development'
    )