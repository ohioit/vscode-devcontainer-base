from flask import Flask, request

import json
import socket

app = Flask(__name__)

@app.route('/')
def index():
    hostname = socket.gethostname()
    client_ip = request.remote_addr
    forwarded_for = request.headers.get('X-Forwarded-For', '')
    forwarded_list = [x.strip() for x in forwarded_for.split(',')] if forwarded_for else []
    return json.dumps({
        'hostname': hostname,
        'client_ip': client_ip,
        'forwarded_for': forwarded_list
    }, indent=2)

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=8080)
