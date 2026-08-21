{
  "log": {
    "level": "warn",
    "timestamp": true
  },
  "inbounds": [
    {
      "type": "vmess",
      "tag": "application-events",
      "listen": "127.0.0.1",
      "listen_port": {{SING_BOX_PORT}},
      "users": [
        {
          "name": "application-client",
          "uuid": "{{UUID}}",
          "alterId": 0
        }
      ],
      "transport": {
        "type": "ws",
        "path": "{{WS_PATH}}",
        "max_early_data": 2048,
        "early_data_header_name": "Sec-WebSocket-Protocol"
      }
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    }
  ],
  "route": {
    "auto_detect_interface": true,
    "final": "direct"
  }
}
