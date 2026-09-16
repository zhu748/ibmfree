[Unit]
Description=Application edge connector
After=network-online.target nginx.service edge-router.service
Wants=network-online.target edge-router.service
Requires=nginx.service

[Service]
Type=simple
User=edge-router
Group=edge-router
ExecStart={{CLOUDFLARED_BIN}} tunnel --no-autoupdate --metrics 127.0.0.1:0 run --token-file {{TOKEN_FILE}}
Restart=on-failure
RestartSec=5s

NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictSUIDSGID=true
LockPersonality=true
CapabilityBoundingSet=
AmbientCapabilities=
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6 AF_NETLINK

[Install]
WantedBy=multi-user.target
