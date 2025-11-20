#!/usr/bin/env python3

import os
import ssl
import urllib.request
import urllib.error
import json
import sys
from pathlib import Path

# --- Configuration ---
ENV_FILE_PATH = Path.home() / "cicd_stack" / "cicd.env"
BASE_URL = "https://artifactory.cicd.local:8082"

# Endpoints
HEALTH_ENDPOINT = f"{BASE_URL}/router/api/v1/system/health"
PING_ENDPOINT = f"{BASE_URL}/artifactory/api/system/ping"
# We use the endpoint you confirmed works with your token
TOKEN_LIST_ENDPOINT = f"{BASE_URL}/access/api/v1/tokens"

def load_env(env_path):
    if not env_path.exists():
        print(f"[FAIL] Configuration error: {env_path} not found.")
        return False

    with open(env_path, 'r') as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith('#') and '=' in line:
                key, value = line.split('=', 1)
                os.environ[key.strip()] = value.strip().strip('"\'')
    return True

def get_ssl_context():
    # Trusts the system CA store (where our Root CA lives)
    return ssl.create_default_context()

def print_response_error(response):
    """Helper to print the full error body for debugging"""
    try:
        body = response.read().decode()
        print(f"       [SERVER RESPONSE]: {body}")
    except Exception:
        print("       [SERVER RESPONSE]: (Could not decode body)")

def check_health():
    print(f"\n--- Test 1: Router Health (Unauthenticated) ---")
    print(f"GET {HEALTH_ENDPOINT}")

    ctx = get_ssl_context()
    try:
        req = urllib.request.Request(HEALTH_ENDPOINT)
        with urllib.request.urlopen(req, context=ctx) as response:
            if response.status == 200:
                data = json.loads(response.read().decode())
                state = data.get('router', {}).get('state', 'UNKNOWN')
                print(f"[PASS] Status: 200 OK")
                print(f"       Router State: {state}")
            else:
                print(f"[FAIL] Status: {response.status}")
                print_response_error(response)
    except urllib.error.HTTPError as e:
        print(f"[FAIL] HTTP {e.code}: {e.reason}")
        print_response_error(e)
    except Exception as e:
        print(f"[FAIL] {e}")

def check_ping():
    print(f"\n--- Test 2: System Ping (Unauthenticated) ---")
    print(f"GET {PING_ENDPOINT}")

    ctx = get_ssl_context()
    try:
        req = urllib.request.Request(PING_ENDPOINT)
        with urllib.request.urlopen(req, context=ctx) as response:
            body = response.read().decode().strip()
            if response.status == 200 and body == "OK":
                print(f"[PASS] Status: 200 OK")
                print(f"       Response: {body}")
            else:
                print(f"[FAIL] Unexpected response: {body}")
    except urllib.error.HTTPError as e:
        print(f"[FAIL] HTTP {e.code}: {e.reason}")
        print_response_error(e)
    except Exception as e:
        print(f"[FAIL] {e}")

def check_admin_token():
    print(f"\n--- Test 3: Admin Token Verification ---")
    print(f"GET {TOKEN_LIST_ENDPOINT}")

    token = os.getenv("ARTIFACTORY_ADMIN_TOKEN")
    if not token:
        print("[SKIP] ARTIFACTORY_ADMIN_TOKEN not found in cicd.env")
        return

    # We use the Bearer header as confirmed by the search AI
    headers = {"Authorization": f"Bearer {token}"}
    ctx = get_ssl_context()

    try:
        req = urllib.request.Request(TOKEN_LIST_ENDPOINT, headers=headers)
        with urllib.request.urlopen(req, context=ctx) as response:
            if response.status == 200:
                data = json.loads(response.read().decode())
                tokens = data.get('tokens', [])
                print(f"[PASS] Status: 200 OK")
                print(f"       Admin Access Confirmed.")
                print(f"       Visible Tokens: {len(tokens)}")
                if len(tokens) > 0:
                    print(f"       First Token ID: {tokens[0].get('token_id')}")
            else:
                print(f"[FAIL] Status: {response.status}")
                print_response_error(response)
    except urllib.error.HTTPError as e:
        print(f"[FAIL] HTTP {e.code}: {e.reason}")
        print_response_error(e)
        if e.code == 403:
            print("       (Token is valid but lacks permission to list tokens)")
        if e.code == 401:
            print("       (Token is invalid or expired)")
    except Exception as e:
        print(f"[FAIL] {e}")

if __name__ == "__main__":
    if load_env(ENV_FILE_PATH):
        check_health()
        check_ping()
        check_admin_token()
        print("\n--- Verification Complete ---")