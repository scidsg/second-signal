from flask import Flask, request, render_template
from twilio.rest import Client
import os

app = Flask(__name__)

@app.route('/')
def index():
    return render_template('index.html')

if __name__ == '__main__':
    app.run(debug=True)

# Load Twilio configuration from environment variables
account_sid = os.getenv('TWILIO_ACCOUNT_SID')
auth_token = os.getenv('TWILIO_AUTH_TOKEN')
twilio_client = Client(account_sid, auth_token)

@app.route('/request_number', methods=['POST'])
def request_number():
    # Logic to request a new phone number from Twilio
    # new_number = twilio_client.incoming_phone_numbers.create(...)

    return "New number requested"

