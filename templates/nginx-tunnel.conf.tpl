map $http_upgrade $edge_connection_upgrade {
    default upgrade;
    ''      close;
}

server {
    listen 127.0.0.1:{{ORIGIN_PORT}};
    server_name {{PUBLIC_DOMAIN}};
    server_tokens off;

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
