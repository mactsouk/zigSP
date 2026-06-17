# Builder stage
FROM alpine:latest AS builder

RUN apk add --no-cache zig build-base

WORKDIR /app
COPY tcp.zig .
COPY udp.zig .

RUN zig build-exe tcp.zig -O ReleaseSafe -target native-native-musl -static -lc
RUN zig build-exe udp.zig -O ReleaseSafe -target native-native-musl -static -lc

# Final image
FROM alpine:latest

WORKDIR /app
COPY --from=builder /app/tcp .
COPY --from=builder /app/udp .

EXPOSE 1234 1235

CMD ["/bin/sh", "-c", "./tcp 1234 & ./udp 1235"]
