#STAGE 1: Build Go binary 
FROM golang:1.26.3-alpine AS builder

WORKDIR /app

# Install build deps
RUN apk add --no-cache git ca-certificates

COPY go.mod go.sum ./
RUN go mod download

COPY . .

# Build the processor Lambda binary
RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 \
    go build -ldflags="-s -w" -o /bin/processor ./cmd/processor

#STAGE 2: Runtime with FFmpeg 
FROM public.ecr.aws/lambda/provided:al2023

# Install FFmpeg with codec support
RUN dnf install -y tar xz && \
    curl -L https://johnvansickle.com/ffmpeg/releases/ffmpeg-release-amd64-static.tar.xz \
    -o /tmp/ffmpeg.tar.xz && \
    tar -xf /tmp/ffmpeg.tar.xz -C /tmp && \
    mv /tmp/ffmpeg-*-static/ffmpeg /usr/local/bin/ffmpeg && \
    mv /tmp/ffmpeg-*-static/ffprobe /usr/local/bin/ffprobe && \
    chmod +x /usr/local/bin/ffmpeg /usr/local/bin/ffprobe && \
    rm -rf /tmp/ffmpeg* && \
    dnf remove -y tar xz && \
    dnf clean all

# Copy binary from builder
COPY --from=builder /bin/processor /var/runtime/bootstrap
RUN chmod +x /var/runtime/bootstrap

# Handler name is ignored for custom runtimes; keep a harmless default.
CMD ["bootstrap"]
