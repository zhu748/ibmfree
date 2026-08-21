[Unit]
Description=Application edge routing service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=edge-router
Group=edge-router
ExecStart={{SING_BOX_BIN}} run -c {{CONFIG_PATH}}
Restart=on-failure
RestartSec=5s
LimitNOFILE=1048576

NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictSUIDSGID=true
LockPersonality=true
MemoryDenyWriteExecute=true
CapabilityBoundingSet=
AmbientCapabilities=
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6 AF_NETLINK

[Install]
WantedBy=multi-user.target
