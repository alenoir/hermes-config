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
      - name: composio-api-key
        value: "$COMPOSIO_API_KEY"
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
            mkdir -p /root/.openclaw /mnt/openclaw-state
            cp -a /mnt/openclaw-state/. /root/.openclaw/ 2>/dev/null || true
            rm -rf /root/.openclaw/plugin-skills
            mkdir -p /root/.openclaw/workspace
            if [ -f /mnt/openclaw-state/config/openclaw.json ]; then
              cp /mnt/openclaw-state/config/openclaw.json /root/.openclaw/openclaw.json
            elif [ -f /mnt/openclaw-state/openclaw.json ]; then
              cp /mnt/openclaw-state/openclaw.json /root/.openclaw/openclaw.json
            else
              cp /app/config/openclaw.json /root/.openclaw/openclaw.json
            fi

            sync_state() {
              while true; do
                sleep 60
                if [ -f /mnt/openclaw-state/openclaw.json ]; then
                  cp /mnt/openclaw-state/openclaw.json /tmp/openclaw-mounted-config.json 2>/dev/null || true
                else
                  rm -f /tmp/openclaw-mounted-config.json
                fi
                cp -aL /root/.openclaw/. /mnt/openclaw-state/ 2>/dev/null || true
                if [ -f /tmp/openclaw-mounted-config.json ]; then
                  cp /tmp/openclaw-mounted-config.json /mnt/openclaw-state/openclaw.json 2>/dev/null || true
                fi
              done
            }

            sync_state &
            sync_pid="$!"
            openclaw gateway --port 18789 --verbose &
            gateway_pid="$!"

            trap 'kill "$sync_pid" 2>/dev/null || true; if [ -f /mnt/openclaw-state/openclaw.json ]; then cp /mnt/openclaw-state/openclaw.json /tmp/openclaw-mounted-config.json 2>/dev/null || true; fi; cp -aL /root/.openclaw/. /mnt/openclaw-state/ 2>/dev/null || true; if [ -f /tmp/openclaw-mounted-config.json ]; then cp /tmp/openclaw-mounted-config.json /mnt/openclaw-state/openclaw.json 2>/dev/null || true; fi; kill "$gateway_pid" 2>/dev/null || true' TERM INT EXIT
            wait "$gateway_pid"
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
          - name: COMPOSIO_API_KEY
            secretRef: composio-api-key
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
          - volumeName: openclaw-runtime
            mountPath: /root/.openclaw
          - volumeName: openclaw-home
            mountPath: /mnt/openclaw-state
    volumes:
      - name: openclaw-runtime
        storageType: EmptyDir
      - name: openclaw-home
        storageType: AzureFile
        storageName: openclaw-home
