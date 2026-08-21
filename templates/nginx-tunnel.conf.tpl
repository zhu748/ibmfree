map $http_upgrade $edge_connection_upgrade {
    default upgrade;
    ''      close;
}

map "$request_method:$http_upgrade" $edge_websocket_request {
    default             0;
    ~*^GET:websocket$   1;
}

server {
    listen 127.0.0.1:{{ORIGIN_PORT}} default_server;
    server_name _;
    server_tokens off;

    return 404;
}

server {
    listen 127.0.0.1:{{ORIGIN_PORT}};
    server_name {{PUBLIC_DOMAIN}};
    server_tokens off;

    root {{SITE_ROOT}};
    index index.html;

    location = {{WS_PATH}} {
        if ($edge_websocket_request = 0) { return 404; }

        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection $edge_connection_upgrade;
        proxy_set_header Host $host;
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
