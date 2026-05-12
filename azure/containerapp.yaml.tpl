identity:
  type: SystemAssigned,UserAssigned
  userAssignedIdentities:
    "$ACR_PULL_ID": {}
properties:
  managedEnvironmentId: $CONTAINERAPP_ENV_ID
  configuration:
    activeRevisionsMode: Single
    registries:
      - server: $ACR_LOGIN_SERVER
        identity: "$ACR_PULL_ID"
    secrets:
      - name: slack-bot-token
        value: "$SLACK_BOT_TOKEN"
      - name: slack-app-token
        value: "$SLACK_APP_TOKEN"
      - name: openclaw-gateway-token
        value: "$OPENCLAW_GATEWAY_TOKEN"
  template:
    scale:
      minReplicas: 1
      maxReplicas: 1
    containers:
      - name: openclaw
        image: $ACR_LOGIN_SERVER/openclaw-agent:$OPENCLAW_IMAGE_TAG
        args:
          - bash
          - -c
          - |
            set -e
            mkdir -p /root/.openclaw/workspace
            if [ ! -f /root/.openclaw/openclaw.json ]; then
              cp /app/config/openclaw.json /root/.openclaw/openclaw.json
            fi
            exec openclaw gateway --port 18789 --verbose
        env:
          - name: OPENCLAW_CONFIG_PATH
            value: /root/.openclaw/openclaw.json
          - name: OPENCLAW_STATE_DIR
            value: /root/.openclaw
          - name: OPENCLAW_CONFIG_DIGEST
            value: "$OPENCLAW_CONFIG_DIGEST"
          - name: OPENCLAW_GATEWAY_TOKEN
            secretRef: openclaw-gateway-token
          - name: SLACK_BOT_TOKEN
            secretRef: slack-bot-token
          - name: SLACK_APP_TOKEN
            secretRef: slack-app-token
          - name: SLACK_ALLOWED_USERS
            value: "$SLACK_ALLOWED_USERS"
        resources:
          cpu: 4
          memory: 8Gi
        probes:
          - type: Liveness
            httpGet:
              path: /healthz
              port: 18789
            initialDelaySeconds: 30
            periodSeconds: 30
          - type: Readiness
            httpGet:
              path: /readyz
              port: 18789
            initialDelaySeconds: 15
            periodSeconds: 15
        volumeMounts:
          - volumeName: openclaw-home
            mountPath: /root/.openclaw
    volumes:
      - name: openclaw-home
        storageType: AzureFile
        storageName: openclaw-home
