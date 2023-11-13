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
apt install -y virtualenv whiptail

# Create a virtual environment in your project directory
cd $HOME
if [ ! -d "second-signal" ]; then
  mkdir second-signal
fi
cd second-signal
python3 -m venv venv
source venv/bin/activate

# Use whiptail to collect environment variables
TWILIO_ACCOUNT_SID=$(whiptail --inputbox "Enter your Twilio Account SID" 20 60 3>&1 1>&2 2>&3)
TWILIO_AUTH_TOKEN=$(whiptail --inputbox "Enter your Twilio Auth Token" 20 60 3>&1 1>&2 2>&3)

# Check if values are provided
if [ -z "$TWILIO_ACCOUNT_SID" ] || [ -z "$TWILIO_AUTH_TOKEN" ]; then
    echo "Twilio Account SID and Auth Token are required."
    exit 1
fi

# Create .env file with the environment variables
cat > .env <<EOL
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
    server_name second-signal.local;
    location / {
        proxy_pass http://127.0.0.1:8000;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
EOL

# Link Nginx server block and restart Nginx
ln -s /etc/nginx/sites-available/second-signal.nginx /etc/nginx/sites-enabled
nginx -t
systemctl restart nginx

# Create Flask app and templates
cat > app.py <<EOL
from dotenv import load_dotenv
load_dotenv()
from flask import Flask, request, render_template
from twilio.rest import Client
import os

app = Flask(__name__)

@app.route('/')
def index():
    return render_template('index.html')

# Load Twilio configuration from environment variables
account_sid = os.getenv('TWILIO_ACCOUNT_SID')
auth_token = os.getenv('TWILIO_AUTH_TOKEN')
twilio_client = Client(account_sid, auth_token)

@app.route('/request_number', methods=['POST'])
def request_number():
    # Logic to request a new phone number from Twilio
    # new_number = twilio_client.incoming_phone_numbers.create(...)

    return "New number requested"

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

# Deactivate the virtual environment
deactivate

# Provide instructions for starting the application with Gunicorn
echo "Setup complete. To start your Flask app, navigate to $HOME/second-signal and run:"
echo "source venv/bin/activate && gunicorn --workers 3 --bind unix:$HOME/second-signal/second-signal.sock app:app"

# Reminder for SSL Configuration
echo "Don't forget to configure SSL for HTTPS in your Nginx server block if needed."