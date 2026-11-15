map $http_upgrade $edge_connection_upgrade {
    default upgrade;
    ''      close;
}

map $http_connection $edge_websocket_connection {
    default 0;
    ~*(^|,)[[:space:]]*upgrade[[:space:]]*(,|$) 1;
}

map $http_sec_websocket_key $edge_websocket_key {
    default 0;
    "~^[A-Za-z0-9+/]{22}==$" 1;
}

# Validate handshake structure only; VMess authentication remains in the core.
map "$request_method:$http_upgrade:$edge_websocket_connection:$edge_websocket_key:$http_sec_websocket_version" $edge_websocket_request {
    default 0;
    "~^GET:(?i:websocket):1:1:13$" 1;
}

log_format edge_minimal '$time_iso8601 $request_method $status $body_bytes_sent $request_time';

server {
    listen 127.0.0.1:{{ORIGIN_PORT}} default_server;
    server_name _;
    server_tokens off;
    access_log /var/log/nginx/access.log edge_minimal;
    error_page 404 =404 @edge_not_found;

    return 404;

    location @edge_not_found {
        default_type text/html;
        return 404 '<!doctype html><html lang="en"><title>Not Found</title><h1>Not Found</h1></html>';
    }
}

server {
    listen 127.0.0.1:{{ORIGIN_PORT}};
    server_name {{PUBLIC_DOMAIN}};
    server_tokens off;
    access_log /var/log/nginx/access.log edge_minimal;
    absolute_redirect off;
    error_page 403 404 =404 @edge_not_found;

    root {{SITE_ROOT}};
    index index.html;
    autoindex off;

{{PROXY_LOCATION}}

    location / {
        try_files $uri $uri/ =404;
    }

    location ~ /\. {
        return 404;
        access_log off;
        log_not_found off;
    }

    location ~* (\.bak($|[./])|\.restore\.|\.(old|orig|save|swp|tmp)$|~$|/(config\.json|client\.txt|tunnel\.token|vless-keys\.json|install-state\.json)$) {
        return 404;
    }

    location @edge_not_found {
        default_type text/html;
        return 404 '<!doctype html><html lang="en"><title>Not Found</title><h1>Not Found</h1></html>';
    }
}
