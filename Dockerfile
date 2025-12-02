# Build stage
# NOTE: This must be built with --platform linux/amd64 because the pre-built
# SoulverCore module in Vendor/ is compiled for x86_64-unknown-linux-gnu.
# We use a base image with a recent glibc (>= 2.38) so it matches the
# `libSoulverCoreDynamic.so` build requirements.
# Example: docker build --platform linux/amd64 -t calcbot .
FROM --platform=linux/amd64 swift:6.1.2-noble AS builder

WORKDIR /build

# Install unzip (needed for SoulverCore binary framework extraction)
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    unzip \
    && rm -rf /var/lib/apt/lists/*

# Copy Package files
COPY Package.swift ./
COPY Package.resolved* ./

# Copy Vendor directory (for Linux SoulverCore libraries)
# Note: This directory must exist with the Linux .so files for the build to work
COPY Vendor ./Vendor

# Resolve dependencies
# Note: SoulverCore will download xcframework (macOS only), but we won't use it on Linux
# The conditional dependency in Package.swift ensures we use Vendor libs instead
RUN swift package resolve

# Copy source code
COPY calcBot ./calcBot

# Build for release
RUN swift build -c release

# Copy binary to a known location for easier extraction
RUN find .build -name calcBot -type f -executable -exec cp {} /calcBot \;

# Runtime stage
FROM --platform=linux/amd64 ubuntu:latest

# Install runtime dependencies
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    ca-certificates \
    libcurl4 \
    libxml2 \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Copy the built binary from builder
COPY --from=builder /calcBot /app/calcBot

# Copy Linux SoulverCore libraries
# The libraries are needed at runtime for the dynamically linked binary
COPY --from=builder /build/Vendor/SoulverCore-linux /app/Vendor/SoulverCore-linux

# Set library path so the binary can find the .so files
ENV LD_LIBRARY_PATH=/app/Vendor/SoulverCore-linux:${LD_LIBRARY_PATH:-}

# Make it executable
RUN chmod +x /app/calcBot

# Set the entrypoint
ENTRYPOINT ["/app/calcBot"]
