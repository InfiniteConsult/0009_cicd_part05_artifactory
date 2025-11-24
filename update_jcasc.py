#!/usr/bin/env python3

import sys
import yaml
import os

# Path to the JCasC file
JCAS_FILE = os.path.expanduser("~/cicd_stack/jenkins/config/jenkins.yaml")

def update_jcasc():
    print(f"[INFO] Reading JCasC file: {JCAS_FILE}")

    try:
        with open(JCAS_FILE, 'r') as f:
            jcasc = yaml.safe_load(f)
    except FileNotFoundError:
        print(f"[ERROR] File not found: {JCAS_FILE}")
        sys.exit(1)

    # 1. Add Artifactory Credentials
    print("[INFO] Injecting Artifactory credentials block...")

    if 'credentials' not in jcasc:
        jcasc['credentials'] = {'system': {'domainCredentials': [{'credentials': []}]}}

    artifactory_cred = {
        'usernamePassword': {
            'id': 'artifactory-creds',
            'scope': 'GLOBAL',
            'description': 'Artifactory Admin Token',
            'username': '${JENKINS_ARTIFACTORY_USERNAME}',
            'password': '${JENKINS_ARTIFACTORY_PASSWORD}'
        }
    }

    # Navigate to credentials list safely
    if 'system' not in jcasc['credentials']:
        jcasc['credentials']['system'] = {'domainCredentials': [{'credentials': []}]}

    domain_creds = jcasc['credentials']['system']['domainCredentials']
    if not domain_creds:
        domain_creds.append({'credentials': []})

    creds_list = domain_creds[0]['credentials']
    if creds_list is None:
        creds_list = []
        domain_creds[0]['credentials'] = creds_list

    # Check existence (Idempotency)
    exists = False
    for cred in creds_list:
        if 'usernamePassword' in cred and cred['usernamePassword'].get('id') == 'artifactory-creds':
            exists = True
            break

    if not exists:
        creds_list.append(artifactory_cred)
        print("[INFO] Credential 'artifactory-creds' added.")
    else:
        print("[INFO] Credential 'artifactory-creds' already exists. Skipping.")

    # 2. Add Artifactory Server Configuration (Updated Schema)
    print("[INFO] Injecting Artifactory Server configuration (v4+ Schema)...")

    if 'unclassified' not in jcasc:
        jcasc['unclassified'] = {}

    # The v4+ Schema: 'jfrogInstances' instead of 'artifactoryServers'
    jcasc['unclassified']['artifactoryBuilder'] = {
        'useCredentialsPlugin': True,
        'jfrogInstances': [{
            'instanceId': 'artifactory',
            'url': '${JENKINS_ARTIFACTORY_URL}',
            'artifactoryUrl': '${JENKINS_ARTIFACTORY_URL}',
            'deployerCredentialsConfig': {
                'credentialsId': 'artifactory-creds'
            },
            'resolverCredentialsConfig': {
                'credentialsId': 'artifactory-creds'
            },
            'bypassProxy': True,
            'connectionRetry': 3,
            'timeout': 300
        }]
    }

    # 3. Write back to file
    print("[INFO] Writing updated JCasC file...")
    with open(JCAS_FILE, 'w') as f:
        yaml.dump(jcasc, f, default_flow_style=False, sort_keys=False)

    print("[INFO] JCasC update complete.")

if __name__ == "__main__":
    update_jcasc()