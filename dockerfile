FROM alpine:3.22

RUN apk add --no-cache rsync

EXPOSE 873/tcp

CMD ["rsync", "--daemon", "--no-detach", "--config=/etc/rsyncd.conf"]
