{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "tag": "application-events",
      "listen": "127.0.0.1",
      "port": {{SING_BOX_PORT}},
      "protocol": "vless",
      "settings": {
        "clients": [ { "id": "{{UUID}}", "email": "application-client" } ],
        "decryption": "{{VLESS_DECRYPTION}}"
      },
      "streamSettings": {
        "network": "xhttp",
        "security": "none",
        "xhttpSettings": {
          "path": "{{WS_PATH}}",
          "mode": "packet-up",
          "extra": { "noSSEHeader": true }
        }
      }
    }
  ],
  "outbounds": [ { "protocol": "freedom", "tag": "direct" } ]
}
