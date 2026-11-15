    location = {{WS_PATH}} {
        if ($edge_websocket_request = 0) { return 404; }

        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection $edge_connection_upgrade;
        proxy_set_header Host $host;
        proxy_hide_header Server;
        proxy_hide_header X-Powered-By;
        proxy_hide_header X-Runtime;
        proxy_hide_header X-AspNet-Version;
        proxy_hide_header X-Generator;
        proxy_hide_header X-Backend-Server;
        proxy_hide_header WWW-Authenticate;
        proxy_hide_header Proxy-Authenticate;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
        proxy_pass http://127.0.0.1:{{SING_BOX_PORT}};
        proxy_intercept_errors on;
        error_page 301 302 303 307 308 400 401 403 404 405 407 426 500 502 503 504 =404 @edge_not_found;
        access_log off;
    }
