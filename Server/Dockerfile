# Multi-stage build for the Calm Frame Vapor server.
# Produces a lean Ubuntu image with only the compiled binary.
#
# Build:  docker build -t calm-frame-server .
# Run:    docker run -p 8080:8080 -e DATABASE_URL=... calm-frame-server

# ── Stage 1: build ───────────────────────────────────────────────────────────
FROM swift:6.0-jammy AS builder

WORKDIR /build

# Copy the local CalmFrameKit package first (referenced as a local path dependency).
COPY ../Packages/CalmFrameKit /build/CalmFrameKit

# Copy the server source.
COPY . /build/Server

WORKDIR /build/Server

# Resolve dependencies and build in release mode.
RUN swift package resolve
RUN swift build -c release --product App

# ── Stage 2: runtime ─────────────────────────────────────────────────────────
FROM ubuntu:jammy

# Install runtime libraries required by Swift and Postgres.
RUN apt-get update && apt-get install -y --no-install-recommends \
    libssl3 \
    libz3-dev \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Copy the compiled binary from the builder stage.
COPY --from=builder /build/Server/.build/release/App /app/App

# Expose the default Vapor port.
EXPOSE 8080

ENTRYPOINT ["/app/App"]
CMD ["serve", "--hostname", "0.0.0.0", "--port", "8080"]
