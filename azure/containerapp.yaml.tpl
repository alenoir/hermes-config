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
      - name: azure-foundry-api-key
        value: "$AZURE_FOUNDRY_API_KEY"
      - name: slack-bot-token
        value: "$SLACK_BOT_TOKEN"
      - name: slack-app-token
        value: "$SLACK_APP_TOKEN"
      - name: google-client-secret-b64
        value: "$GOOGLE_CLIENT_SECRET_B64"
      - name: google-token-b64
        value: "$GOOGLE_TOKEN_B64"
      - name: composio-api-key
        value: "$COMPOSIO_API_KEY"
  template:
    scale:
      minReplicas: 1
      maxReplicas: 1
    containers:
      - name: hermes
        image: $ACR_LOGIN_SERVER/hermes-agent:$HERMES_IMAGE_TAG
        args:
          - bash
          - -c
          - |
            set -e
            cp /mnt/bootstrap/config.yaml /opt/data/config.yaml
            cp /mnt/bootstrap/SOUL.md /opt/data/SOUL.md
            if [ -n "$GOOGLE_CLIENT_SECRET_B64" ] && [ "$GOOGLE_CLIENT_SECRET_B64" != "-" ]; then
              printf '%s' "$GOOGLE_CLIENT_SECRET_B64" | base64 -d > /opt/data/google_client_secret.json
              chmod 600 /opt/data/google_client_secret.json
            fi
            if [ -n "$GOOGLE_TOKEN_B64" ] && [ "$GOOGLE_TOKEN_B64" != "-" ]; then
              printf '%s' "$GOOGLE_TOKEN_B64" | base64 -d > /opt/data/google_token.json
              chmod 600 /opt/data/google_token.json
            fi
            mkdir -p /opt/data/logs
            touch /opt/data/logs/agent.log /opt/data/logs/gateway.log /opt/data/logs/errors.log
            if [ "${HERMES_TAIL_FILE_LOGS:-true}" = "true" ]; then
              tail -n 0 -F /opt/data/logs/agent.log /opt/data/logs/gateway.log /opt/data/logs/errors.log &
            fi
            exec /opt/hermes/.venv/bin/hermes gateway run --accept-hooks
        env:
          - name: HERMES_HOME
            value: /opt/data
          - name: HERMES_MODEL
            value: "$HERMES_MODEL"
          - name: HERMES_TAIL_FILE_LOGS
            value: "$HERMES_TAIL_FILE_LOGS"
          - name: HERMES_CONFIG_DIGEST
            value: "$HERMES_CONFIG_DIGEST"
          - name: HERMES_UID
            value: "10000"
          - name: HERMES_GID
            value: "10000"
          - name: AZURE_FOUNDRY_BASE_URL
            value: "$AZURE_FOUNDRY_BASE_URL"
          - name: AZURE_FOUNDRY_API_KEY
            secretRef: azure-foundry-api-key
          - name: SLACK_BOT_TOKEN
            secretRef: slack-bot-token
          - name: SLACK_APP_TOKEN
            secretRef: slack-app-token
          - name: SLACK_ALLOWED_USERS
            value: "$SLACK_ALLOWED_USERS"
          - name: SLACK_HOME_CHANNEL
            value: "$SLACK_HOME_CHANNEL"
          - name: SLACK_HOME_CHANNEL_NAME
            value: "$SLACK_HOME_CHANNEL_NAME"
          - name: GOOGLE_CLIENT_SECRET_B64
            secretRef: google-client-secret-b64
          - name: GOOGLE_TOKEN_B64
            secretRef: google-token-b64
          - name: COMPOSIO_API_KEY
            secretRef: composio-api-key
        resources:
          cpu: 2
          memory: 4Gi
        volumeMounts:
          - volumeName: hermes-home
            mountPath: /opt/data
          - volumeName: hermes-bootstrap
            mountPath: /mnt/bootstrap
    volumes:
      - name: hermes-home
        storageType: EmptyDir
      - name: hermes-bootstrap
        storageType: AzureFile
        storageName: hermes-home
