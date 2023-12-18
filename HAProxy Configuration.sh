global
       # Default SSL material locations
        ca-base /certs
        crt-base /certs

        # See: https://ssl-config.mozilla.org/#server=haproxy&server-version=2.0.3&config=intermediate
        ssl-default-bind-ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POL>
        ssl-default-bind-ciphersuites TLS_AES_128_GCM_SHA256:TLS_AES_256_GCM_SHA384:TLS_CHACHA20_POLY1305_SHA256
        ssl-default-bind-options ssl-min-ver TLSv1.2 no-tls-tickets

defaults
        log     global
        mode    http
        option  httplog
        option  dontlognull
        timeout connect 5000
        timeout client  50000
        timeout server  50000

frontend stats
    mode http
    bind *:8404
    stats enable
    stats uri /monitoring
    stats refresh 10s
    stats auth halb:halb

# Load Balancing for Apache Cluster
frontend apache_front
        bind *:443 ssl crt /certs/
        option             forwardfor
        acl url_discovery path /.well-known/caldav /.well-known/carddav
        http-request redirect location /remote.php/dav/ code 301 if url_discovery
        default_backend apache_backend_servers

    # HSTS
    http-response set-header Strict-Transport-Security "max-age=16000000; includeSubDomains; preload;"

resolvers docker
    nameserver dns1 127.0.0.11:53

backend apache_backend_servers
        balance roundrobin
        option http-keep-alive
        option forwardfor
        cookie SRVNAME insert indirect preserve nocache httponly secure
        timeout connect  30000
        timeout client  30000
        timeout server 30000
        server app-next-01 app-next-01:8081 cookie next01 check
        server app-next-02 app-next-02:8082 cookie next02 check
        server app-next-03 app-next-03:8083 cookie next03 check
        server app-next-04 app-next-04:8084 cookie next04 check
        server app-next-05 app-next-05:8085 cookie next05 check
        server app-next-06 app-next-06:8086 cookie next06 check
        server app-next-07 app-next-07:8087 cookie next07 check
        server app-next-08 app-next-08:8088 cookie next08 check
        server app-next-09 app-next-09:8089 cookie next09 check
       
        
# Load Balancing for CODE Cluster
frontend coolwsd
  bind *:9980 ssl crt /certs/
  mode http
  default_backend coolwsd

backend coolwsd
  balance roundrobin
  timeout tunnel 3600s
  mode http
  balance url_param WOPISrc check_post
  cookie HAPLB insert indirect preserve nocache httponly secure
  hash-type consistent
  server code-node1 code-node1:9001 cookie wsd01 check
  server code-node2 code-node2:9002 cookie wsd02 check
  server code-node3 code-node3:9003 cookie wsd03 check
  server code-node4 code-node4:9004 cookie wsd04 check
  server code-node5 code-node5:9005 cookie wsd05 check
  server code-node6 code-node6:9006 cookie wsd06 check
  server code-node7 code-node7:9007 cookie wsd07 check
  server code-node8 code-node8:9008 cookie wsd08 check
  server code-node9 code-node9:9009 cookie wsd09 check
  

# Load Balancing for Galera Cluster
listen galera
bind *:3306
   option mysql-check user haproxy
   mode tcp
   option tcpka
   balance leastconn
   server mariadb-node1 mariadb-node1:8001 check inter 5000 fastinter 2000 rise 2 fall 2
   server mariadb-node2 mariadb-node2:8002 check inter 5000 fastinter 2000 rise 2 fall 2
   server mariadb-node3 mariadb-node3:8003 check inter 5000 fastinter 2000 rise 2 fall 2
   server mariadb-node4 mariadb-node4:8004 check inter 5000 fastinter 2000 rise 2 fall 2
   server mariadb-node5 mariadb-node5:8005 check inter 5000 fastinter 2000 rise 2 fall 2
   server mariadb-node6 mariadb-node6:8006 check inter 5000 fastinter 2000 rise 2 fall 2
   server mariadb-node7 mariadb-node7:8007 check inter 5000 fastinter 2000 rise 2 fall 2
   server mariadb-node8 mariadb-node8:8008 check inter 5000 fastinter 2000 rise 2 fall 2
   server mariadb-node9 mariadb-node9:8009 check inter 5000 fastinter 2000 rise 2 fall 2
   

# Load Balancing for Redis Cluster
backend bk_redis
    balance leastconn
    mode tcp
    option tcp-smart-accept
    option tcp-smart-connect
    option tcpka
    option tcplog
    option tcp-check
    tcp-check connect
    tcp-check send AUTH\ pass\r\n
    tcp-check send PING\r\n
    tcp-check expect string +PONG
    tcp-check send info\ replication\r\n
    tcp-check expect string role:master
    tcp-check send QUIT\r\n
    tcp-check expect string +OK
    server redis-node1 redis-node1:7001 check inter 1s
    server redis-node2 redis-node2:7002 check inter 1s
    server redis-node3 redis-node3:7003 check inter 1s
    server redis-node4 redis-node4:7004 check inter 1s
    server redis-node5 redis-node5:7005 check inter 1s
    server redis-node6 redis-node6:7006 check inter 1s
    server redis-node7 redis-node7:7007 check inter 1s
    server redis-node8 redis-node8:7008 check inter 1s
    server redis-node9 redis-node9:7009 check inter 1s
    server redis-node10 redis-node10:7010 check inter 1s
    server redis-node11 redis-node11:7011 check inter 1s
    server redis-node12 redis-node12:7012 check inter 1s
    server redis-node13 redis-node13:7013 check inter 1s
    server redis-node14 redis-node14:7014 check inter 1s
    server redis-node15 redis-node15:7015 check inter 1s
    server redis-node16 redis-node16:7016 check inter 1s
    server redis-node17 redis-node17:7017 check inter 1s
    server redis-node18 redis-node18:7018 check inter 1s
   