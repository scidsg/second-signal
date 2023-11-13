#!/bin/bash

# Run as root
if [[ $EUID -ne 0 ]]; then
  echo "This script needs to run as root. Elevating permissions now."
  exec sudo /bin/bash "$0" "$@"
fi

# Update and upgrade packages
apt update && apt -y dist-upgrade && apt -y autoremove

# Install Python and Pip
apt install python3 python3-pip -y

# Install virtualenv and whiptail
apt install -y python3 python3-pip virtualenv python3-venv whiptail ufw certbot python3-certbot-nginx

# Create a virtual environment in your project directory
cd $HOME
if [ ! -d "second-signal" ]; then
  mkdir second-signal
fi
cd second-signal
python3 -m venv venv
source venv/bin/activate

# Ask if the user wants to set up a domain name
if (whiptail --title "Domain Setup" --yesno "Do you want to set up a domain name?" 10 60); then
    # If yes, ask for the domain name
    DOMAIN=$(whiptail --inputbox "Enter your domain name" 10 60 3>&1 1>&2 2>&3)
else
    DOMAIN="localhost"
fi

# Use whiptail to collect environment variables
TWILIO_ACCOUNT_SID=$(whiptail --inputbox "Enter your Twilio Account SID" 20 60 3>&1 1>&2 2>&3)
TWILIO_AUTH_TOKEN=$(whiptail --inputbox "Enter your Twilio Auth Token" 20 60 3>&1 1>&2 2>&3)
FLASK_SECRET_KEY=$(openssl rand -hex 16)

# Check if values are provided
if [ -z "$TWILIO_ACCOUNT_SID" ] || [ -z "$TWILIO_AUTH_TOKEN" ]; then
    echo "Twilio Account SID and Auth Token are required."
    exit 1
fi

# Create .env file with the environment variables
cat > .env <<EOL
FLASK_SECRET_KEY=$FLASK_SECRET_KEY
TWILIO_ACCOUNT_SID=$TWILIO_ACCOUNT_SID
TWILIO_AUTH_TOKEN=$TWILIO_AUTH_TOKEN
EOL

# Ensure requirements.txt is present
if [ ! -f "requirements.txt" ]; then
    echo "requirements.txt not found."
    exit 1
fi

# Install dependencies inside the virtual environment
pip install -r requirements.txt

# Install Gunicorn
pip install gunicorn

# Install Nginx
apt install nginx -y

# Allow HTTP and HTTPS traffic
ufw allow 'Nginx Full'

# Create Nginx server block
cat > /etc/nginx/sites-available/second-signal.nginx <<EOL
server {
    listen 80;
    server_name $DOMAIN;

    location / {
		proxy_pass http://127.0.0.1:8000;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOL

# Link Nginx server block and restart Nginx
# Remove existing symbolic link if it exists
if [ -L /etc/nginx/sites-enabled/second-signal.nginx ]; then
    rm /etc/nginx/sites-enabled/second-signal.nginx
fi

# Create a new symbolic link
ln -s /etc/nginx/sites-available/second-signal.nginx /etc/nginx/sites-enabled
nginx -t
systemctl restart nginx

# Create Flask app and templates
cat > app.py <<EOL
from dotenv import load_dotenv
load_dotenv()
from flask import Flask, request, render_template, jsonify, redirect, url_for, session, flash
from twilio.rest import Client
from twilio.base.exceptions import TwilioRestException
import os
from flask_sqlalchemy import SQLAlchemy

app = Flask(__name__)
app.config['SQLALCHEMY_DATABASE_URI'] = 'sqlite:///messages.db'
app.config['SQLALCHEMY_TRACK_MODIFICATIONS'] = False
db = SQLAlchemy(app)

class Message(db.Model):
    id = db.Column(db.Integer, primary_key=True)
    from_number = db.Column(db.String(50))
    body = db.Column(db.String(1600))

    def __repr__(self):
        return f"<Message from {self.from_number}>"

# Set the secret key from an environment variable
app.secret_key = os.getenv('FLASK_SECRET_KEY')
if not app.secret_key:
    raise RuntimeError("FLASK_SECRET_KEY is not set in the environment variables")

@app.route('/')
def index():
    return render_template('index.html')

# Load Twilio configuration from environment variables
account_sid = os.getenv('TWILIO_ACCOUNT_SID')
auth_token = os.getenv('TWILIO_AUTH_TOKEN')
twilio_client = Client(account_sid, auth_token)

@app.route('/request_number', methods=['POST'])
def request_number():
    try:
        desired_area_code = "415"  # Replace with the desired area code
        new_number = twilio_client.incoming_phone_numbers.create(
            area_code=desired_area_code
        )
        session['new_number'] = new_number.phone_number  # Store the number in the session
        return redirect(url_for('show_number'))  # Redirect to the new route
    except TwilioRestException as e:
        flash(f"Failed to request new number: {e}")  # Flash an error message
        return redirect(url_for('index'))  # Redirect back to the index page

@app.route('/show_number')
def show_number():
    new_number = session.get('new_number', None)  # Retrieve the number from the session
    return render_template('show_number.html', phone_number=new_number)  # Render the template

messages = []

@app.route('/sms', methods=['POST'])
def sms_received():
    from_number = request.form['From']
    message_body = request.form['Body']
    message = Message(from_number=from_number, body=message_body)
    db.session.add(message)
    db.session.commit()
    return "<Response></Response>"

@app.route('/get_messages')
def get_messages():
    messages = Message.query.order_by(Message.id.desc()).all()
    return jsonify([{'from': m.from_number, 'body': m.body} for m in messages])

if __name__ == '__main__':
    app.run(debug=True)
EOL

mkdir templates
cat > templates/index.html <<EOL
<!DOCTYPE html>
<html>
<head>
    <title>Phone Number Request</title>
</head>
<body>
    <form action="/request_number" method="post">
        <input type="submit" value="Request New Number">
    </form>
</body>
</html>
EOL

cat > templates/sms.html <<EOL
<!DOCTYPE html>
<html>
<head>
    <title>SMS Messages</title>
    <script src="https://code.jquery.com/jquery-3.6.0.min.js"></script>
	<script>
	    \$(document).ready(function() {
	        var lastMessageId = null; // Initialize last message ID

	        function fetchMessages() {
	            $.getJSON('/get_messages', function(data) {
	                data.forEach(function(message) {
	                    if (lastMessageId === null || message.id > lastMessageId) {
	                        \$('#messages').append(
	                            '<div class="message"><strong>' + message.from + ':</strong> ' + message.body + '</div>'
	                        );
	                        lastMessageId = message.id; // Update the last message ID
	                    }
	                });
	            });
	        }

	        // Poll for new messages every 5 seconds
	        setInterval(fetchMessages, 5000);
	    });
	</script>
</head>
<body>
    <div id="messages">Loading messages...</div>
</body>
</html>
EOL

cat > templates/show_number.html <<EOL
<!DOCTYPE html>
<html>
<head>
    <title>New Phone Number</title>
    <script src="https://code.jquery.com/jquery-3.6.0.min.js"></script>
	<script>
    \$(document).ready(function() {
        var lastMessageId = null; // Initialize last message ID

        function fetchMessages() {
            $.getJSON('/get_messages', function(data) {
                data.forEach(function(message) {
                    if (lastMessageId === null || message.id > lastMessageId) {
                        \$('#messages').append(
                            '<div class="message"><strong>' + message.from + ':</strong> ' + message.body + '</div>'
                        );
                        lastMessageId = message.id; // Update the last message ID
                    }
                });
            });
        }

        // Poll for new messages every 5 seconds
        setInterval(fetchMessages, 5000);
    });
</script>

</head>
<body>
    {% if phone_number %}
        <h1>Your new phone number: {{ phone_number }}</h1>
        <div id="messages">Loading messages...</div>
    {% else %}
        <h1>No new number to display.</h1>
    {% endif %}
    <a href="{{ url_for('index') }}">Go back</a>
</body>
</html>
EOL

cat > init_db.py <<EOL
from app import db
db.create_all()
EOL

python3 init_db.py

# Deactivate the virtual environment
deactivate

if [ "$DOMAIN" != "localhost" ]; then
    whiptail --title "DNS Configuration" --msgbox "Ensure your domain name's DNS settings are correctly configured:\n\n1. Set an A record that points your domain to your server's public IP address.\n2. Wait for the DNS changes to propagate, which might take some time.\n\nAfter confirming these settings, the script will attempt to acquire an SSL certificate for your domain." 15 60
    
    # Proceed to request SSL certificate
    certbot --nginx --non-interactive --agree-tos --redirect --no-eff-email --email your-email@example.com -d $DOMAIN
fi

systemctl enable certbot.timer
systemctl start certbot.timer

# Provide instructions for starting the application with Gunicorn
echo "Setup complete. To start your Flask app, navigate to $HOME/second-signal and run:"
echo "source venv/bin/activate && gunicorn --workers 3 --bind 0.0.0.0:8000 app:app"

# Reminder for SSL Configuration
echo "Don't forget to configure SSL for HTTPS in your Nginx server block if needed."