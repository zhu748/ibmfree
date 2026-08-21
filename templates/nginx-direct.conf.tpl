map $http_upgrade $edge_connection_upgrade {
    default upgrade;
    ''      close;
}

server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name {{PUBLIC_DOMAIN}};
    server_tokens off;

    ssl_certificate {{TLS_CERT_PATH}};
    ssl_certificate_key {{TLS_KEY_PATH}};
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_session_cache shared:TLS:10m;
    ssl_session_timeout 1d;
    ssl_session_tickets off;

    add_header Strict-Transport-Security "max-age=31536000" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;

    root {{SITE_ROOT}};
    index index.html;

    location = {{WS_PATH}} {
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection $edge_connection_upgrade;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
        proxy_pass http://127.0.0.1:{{SING_BOX_PORT}};
        access_log off;
    }

    location / {
        try_files $uri $uri/ =404;
    }

    location ~ /\. {
        deny all;
        access_log off;
        log_not_found off;
    }
}
