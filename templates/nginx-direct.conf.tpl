map $http_upgrade $edge_connection_upgrade {
    default upgrade;
    ''      close;
}

map "$request_method:$http_upgrade" $edge_websocket_request {
    default             0;
    ~*^GET:websocket$   1;
}

log_format edge_minimal '$time_iso8601 $request_method $status $body_bytes_sent $request_time';

server {
    listen 443 ssl default_server;
    listen [::]:443 ssl default_server;
    server_name _;
    server_tokens off;
    access_log /var/log/nginx/access.log edge_minimal;
    error_page 404 =404 @edge_not_found;

    ssl_certificate {{TLS_CERT_PATH}};
    ssl_certificate_key {{TLS_KEY_PATH}};
    ssl_reject_handshake on;
    return 404;

    location @edge_not_found {
        default_type text/html;
        return 404 '<!doctype html><html lang="en"><title>Not Found</title><h1>Not Found</h1></html>';
    }
}

server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name {{PUBLIC_DOMAIN}};
    server_tokens off;
    access_log /var/log/nginx/access.log edge_minimal;
    absolute_redirect off;
    error_page 403 404 =404 @edge_not_found;

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
    autoindex off;

    location = {{WS_PATH}} {
        if ($edge_websocket_request = 0) { return 404; }

        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection $edge_connection_upgrade;
        proxy_set_header Host $host;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
        proxy_pass http://127.0.0.1:{{SING_BOX_PORT}};
        proxy_intercept_errors on;
        error_page 400 403 404 405 426 500 502 503 504 =404 @edge_not_found;
        access_log off;
    }

    location / {
        try_files $uri $uri/ =404;
    }

    location ~ /\. {
        return 404;
        access_log off;
        log_not_found off;
    }

    location ~* (\.bak($|[./])|\.restore\.|\.(old|orig|save|swp|tmp)$|~$|/(config\.json|client\.txt|tunnel\.token)$) {
        return 404;
    }

    location @edge_not_found {
        default_type text/html;
        return 404 '<!doctype html><html lang="en"><title>Not Found</title><h1>Not Found</h1></html>';
    }
}
