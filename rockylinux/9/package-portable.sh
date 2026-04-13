#!/bin/bash
# Portable Tengine Package Creator
# This script extracts a built Tengine container into a portable directory structure

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE_NAME="${1:-tengine:rockylinux9}"
OUTPUT_DIR="${2:-tengine-portable}"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)

echo "==================================================="
echo "Tengine Portable Package Creator"
echo "==================================================="
echo "Image: $IMAGE_NAME"
echo "Output: $OUTPUT_DIR"
echo ""

# Check if Docker image exists
if ! docker image inspect "$IMAGE_NAME" >/dev/null 2>&1; then
    echo "Error: Docker image '$IMAGE_NAME' not found."
    echo "Building image from Dockerfile..."
    docker build -f "$SCRIPT_DIR/Dockerfile" -t "$IMAGE_NAME" "$SCRIPT_DIR/../.."
fi

# Create output directory structure
echo "Creating directory structure..."
rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR"/{opt,usr/sbin,etc,var/lib/nginx,var/log/nginx}

# Create temporary container
echo "Creating temporary container..."
CONTAINER_ID=$(docker create "$IMAGE_NAME")

# Extract files from container
echo "Extracting Tengine installation..."
docker cp "$CONTAINER_ID:/opt/tengine" "$OUTPUT_DIR/opt/" 2>/dev/null || true
docker cp "$CONTAINER_ID:/usr/sbin/nginx" "$OUTPUT_DIR/usr/sbin/" 2>/dev/null || true
docker cp "$CONTAINER_ID:/etc/nginx" "$OUTPUT_DIR/etc/" 2>/dev/null || true
docker cp "$CONTAINER_ID:/docker-entrypoint.sh" "$OUTPUT_DIR/" 2>/dev/null || true

# Clean up container
echo "Cleaning up temporary container..."
docker rm "$CONTAINER_ID" >/dev/null

# Check extracted binary
if [ ! -f "$OUTPUT_DIR/usr/sbin/nginx" ]; then
    echo "Error: Failed to extract nginx binary"
    exit 1
fi

# Get version info
echo "Checking extracted binary..."
NGINX_VERSION=$(docker run --rm "$IMAGE_NAME" /usr/sbin/nginx -v 2>&1 | grep -o 'Tengine/[^ ]*' || echo "unknown")

# Create installation script
echo "Creating installation script..."
cat > "$OUTPUT_DIR/install.sh" << 'EOF'
#!/bin/bash
# Tengine Portable Installation Script

set -e

INSTALL_PREFIX="${1:-/}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "==================================================="
echo "Tengine Portable Installation"
echo "==================================================="
echo "Install prefix: $INSTALL_PREFIX"
echo ""

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    echo "Warning: Not running as root. Some operations may fail."
    echo "Consider running with sudo for system-wide installation."
    echo ""
fi

# Detect OS and package manager
detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$ID
        VERSION=$VERSION_ID
    else
        echo "Error: Cannot detect OS"
        exit 1
    fi
}

# Install runtime dependencies
install_dependencies() {
    echo "Checking runtime dependencies..."

    detect_os

    case "$OS" in
        rocky|rhel|centos|almalinux|fedora)
            PKG_CMD="dnf install -y"
            [ "$OS" = "centos" ] && PKG_CMD="yum install -y"
            PACKAGES="gd libxslt libxml2 libmaxminddb"
            ;;
        ubuntu|debian)
            PKG_CMD="apt-get install -y"
            PACKAGES="libgd3 libxslt1.1 libxml2 libmaxminddb0"
            ;;
        *)
            echo "Warning: Unsupported OS '$OS'. You may need to install dependencies manually:"
            echo "  - gd (libgd)"
            echo "  - libxslt"
            echo "  - libxml2"
            echo "  - libmaxminddb"
            return
            ;;
    esac

    if [ "$EUID" -eq 0 ]; then
        echo "Installing: $PACKAGES"
        $PKG_CMD $PACKAGES || {
            echo "Warning: Failed to install some dependencies. Continuing anyway..."
        }
    else
        echo "Please install these packages manually:"
        echo "  $PKG_CMD $PACKAGES"
    fi
}

# Copy files
install_files() {
    echo "Copying files to $INSTALL_PREFIX..."

    # Create directories
    mkdir -p "$INSTALL_PREFIX/opt" "$INSTALL_PREFIX/usr/sbin" "$INSTALL_PREFIX/etc"
    mkdir -p "$INSTALL_PREFIX/var/lib/nginx" "$INSTALL_PREFIX/var/log/nginx"

    # Copy tengine files
    cp -rf "$SCRIPT_DIR/opt/tengine" "$INSTALL_PREFIX/opt/"
    cp -f "$SCRIPT_DIR/usr/sbin/nginx" "$INSTALL_PREFIX/usr/sbin/"
    cp -rf "$SCRIPT_DIR/etc/nginx" "$INSTALL_PREFIX/etc/"

    # Set permissions
    chmod +x "$INSTALL_PREFIX/usr/sbin/nginx"

    echo "Files installed successfully."
}

# Create nginx user
create_user() {
    if [ "$EUID" -eq 0 ]; then
        echo "Creating nginx user..."
        if ! getent group nginx >/dev/null 2>&1; then
            groupadd -r nginx -g 101 || groupadd -r nginx
        fi
        if ! getent passwd nginx >/dev/null 2>&1; then
            useradd -r -u 101 -g nginx -s /sbin/nologin \
                -d /var/lib/nginx -m -c "nginx user" nginx 2>/dev/null || \
            useradd -r -g nginx -s /sbin/nologin \
                -d /var/lib/nginx -m -c "nginx user" nginx
        fi
    else
        echo "Skipping user creation (not root). Ensure 'nginx' user exists."
    fi
}

# Set ownership
set_ownership() {
    if [ "$EUID" -eq 0 ]; then
        echo "Setting ownership..."
        chown -R nginx:nginx "$INSTALL_PREFIX/var/lib/nginx" "$INSTALL_PREFIX/var/log/nginx" || true
    fi
}

# Verify installation
verify_installation() {
    echo ""
    echo "Verifying installation..."

    # Set environment variables for testing
    export LUA_PATH="/opt/tengine/lualib/?.lua;/opt/tengine/lualib/?/init.lua;/opt/tengine/luajit/share/luajit-2.1/?.lua;./?.lua;/usr/local/share/luajit-2.1/?.lua;/usr/local/share/lua/5.1/?.lua;/usr/local/share/lua/5.1/?/init.lua"
    export LUA_CPATH="/opt/tengine/luamod/?.so;./?.so;/usr/local/lib/lua/5.1/?.so;/usr/local/lib/lua/5.1/loadall.so"
    export PATH="/opt/tengine/geoip/bin:/opt/tengine/luajit/bin:/opt/tengine/Tongsuo/bin:/opt/tengine/pcre2/bin:$PATH"

    if "$INSTALL_PREFIX/usr/sbin/nginx" -t 2>&1 | grep -q "successful"; then
        echo "✓ Configuration test passed"
        "$INSTALL_PREFIX/usr/sbin/nginx" -V
        echo ""
        echo "==================================================="
        echo "Installation completed successfully!"
        echo "==================================================="
        echo ""
        echo "To start Tengine:"
        echo "  $INSTALL_PREFIX/usr/sbin/nginx"
        echo ""
        echo "To stop Tengine:"
        echo "  $INSTALL_PREFIX/usr/sbin/nginx -s stop"
        echo ""
        echo "To reload configuration:"
        echo "  $INSTALL_PREFIX/usr/sbin/nginx -s reload"
        echo ""
    else
        echo "✗ Configuration test failed"
        echo "Please check the error messages above."
        exit 1
    fi
}

# Main installation process
main() {
    install_dependencies
    install_files
    create_user
    set_ownership
    verify_installation
}

main
EOF

chmod +x "$OUTPUT_DIR/install.sh"

# Create uninstall script
echo "Creating uninstall script..."
cat > "$OUTPUT_DIR/uninstall.sh" << 'EOF'
#!/bin/bash
# Tengine Portable Uninstallation Script

set -e

INSTALL_PREFIX="${1:-/}"

echo "==================================================="
echo "Tengine Portable Uninstallation"
echo "==================================================="
echo "Install prefix: $INSTALL_PREFIX"
echo ""

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    echo "Warning: Not running as root. Some operations may fail."
    read -p "Continue anyway? (y/N) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 1
    fi
fi

# Stop nginx if running
if pgrep nginx >/dev/null; then
    echo "Stopping nginx..."
    "$INSTALL_PREFIX/usr/sbin/nginx" -s stop 2>/dev/null || killall nginx 2>/dev/null || true
    sleep 2
fi

# Remove files
echo "Removing files..."
rm -rf "$INSTALL_PREFIX/opt/tengine"
rm -f "$INSTALL_PREFIX/usr/sbin/nginx"
rm -rf "$INSTALL_PREFIX/etc/nginx"
rm -rf "$INSTALL_PREFIX/var/lib/nginx"
rm -rf "$INSTALL_PREFIX/var/log/nginx"

echo "Tengine has been uninstalled."
echo ""
echo "Note: nginx user and runtime dependencies were not removed."
echo "You can remove them manually if needed."
EOF

chmod +x "$OUTPUT_DIR/uninstall.sh"

# Create systemd service file
echo "Creating systemd service file..."
cat > "$OUTPUT_DIR/tengine.service" << 'EOF'
[Unit]
Description=Tengine - high performance web server
Documentation=https://tengine.taobao.org/
After=network.target remote-fs.target nss-lookup.target

[Service]
Type=forking
PIDFile=/run/nginx.pid
Environment="LUA_PATH=/opt/tengine/lualib/?.lua;/opt/tengine/lualib/?/init.lua;/opt/tengine/luajit/share/luajit-2.1/?.lua;./?.lua;/usr/local/share/luajit-2.1/?.lua;/usr/local/share/lua/5.1/?.lua;/usr/local/share/lua/5.1/?/init.lua"
Environment="LUA_CPATH=/opt/tengine/luamod/?.so;./?.so;/usr/local/lib/lua/5.1/?.so;/usr/local/lib/lua/5.1/loadall.so"
Environment="PATH=/opt/tengine/geoip/bin:/opt/tengine/luajit/bin:/opt/tengine/Tongsuo/bin:/opt/tengine/pcre2/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
ExecStartPre=/usr/sbin/nginx -t
ExecStart=/usr/sbin/nginx
ExecReload=/bin/kill -s HUP $MAINPID
ExecStop=/bin/kill -s QUIT $MAINPID
PrivateTmp=true
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

# Create startup script
echo "Creating startup script..."
cat > "$OUTPUT_DIR/start-tengine.sh" << 'EOF'
#!/bin/bash
# Tengine Startup Script

# Set environment variables
export LUA_PATH="/opt/tengine/lualib/?.lua;/opt/tengine/lualib/?/init.lua;/opt/tengine/luajit/share/luajit-2.1/?.lua;./?.lua;/usr/local/share/luajit-2.1/?.lua;/usr/local/share/lua/5.1/?.lua;/usr/local/share/lua/5.1/?/init.lua"
export LUA_CPATH="/opt/tengine/luamod/?.so;./?.so;/usr/local/lib/lua/5.1/?.so;/usr/local/lib/lua/5.1/loadall.so"
export PATH="/opt/tengine/geoip/bin:/opt/tengine/luajit/bin:/opt/tengine/Tongsuo/bin:/opt/tengine/pcre2/bin:$PATH"

# Start Tengine
exec /usr/sbin/nginx -g "daemon off;"
EOF

chmod +x "$OUTPUT_DIR/start-tengine.sh"

# Create README
echo "Creating README..."
cat > "$OUTPUT_DIR/README.md" << EOF
# Tengine Portable Package

Version: $NGINX_VERSION
Build Date: $TIMESTAMP
Architecture: x86_64

## What's Included

This is a portable Tengine package that includes:

- Tengine server with all modules
- LuaJIT and Lua libraries
- Tongsuo (GMSSL) for national cryptographic standards
- PCRE2, zlib, Brotli, GeoIP
- All required libraries bundled via RPATH

## System Requirements

### Minimum Requirements
- **OS**: Linux x86_64
- **glibc**: 2.34 or higher
- **Kernel**: 3.10 or higher

### Runtime Dependencies
The following system libraries must be installed on the target machine:
- \`libgd\` (for image processing)
- \`libxslt\` (for XSLT support)
- \`libxml2\` (for XML support)
- \`libmaxminddb\` (for GeoIP2 support)

These will be automatically installed by the installation script if you run it as root.

## Compatible Operating Systems

✓ **Fully Compatible:**
- RockyLinux 9, AlmaLinux 9, RHEL 9
- Fedora 35+
- Ubuntu 22.04+
- Debian 11+
- Other modern Linux distributions with glibc 2.34+

✗ **Not Compatible:**
- Alpine Linux (uses musl libc instead of glibc)
- Very old distributions (glibc < 2.34)
- Non-x86_64 architectures

## Installation

### Quick Install (System-wide)

\`\`\`bash
sudo ./install.sh
\`\`\`

This will:
1. Install runtime dependencies
2. Copy files to system directories
3. Create nginx user
4. Verify the installation

### Custom Prefix Install

\`\`\`bash
sudo ./install.sh /opt/custom
\`\`\`

### Manual Installation

If you prefer to install manually:

\`\`\`bash
# Install dependencies (RHEL/Rocky/Fedora)
sudo dnf install -y gd libxslt libxml2 libmaxminddb

# Install dependencies (Ubuntu/Debian)
sudo apt-get install -y libgd3 libxslt1.1 libxml2 libmaxminddb0

# Copy files
sudo cp -r opt/tengine /opt/
sudo cp usr/sbin/nginx /usr/sbin/
sudo cp -r etc/nginx /etc/

# Create nginx user
sudo groupadd -r nginx
sudo useradd -r -g nginx -s /sbin/nologin -d /var/lib/nginx nginx

# Create required directories
sudo mkdir -p /var/lib/nginx /var/log/nginx
sudo chown -R nginx:nginx /var/lib/nginx /var/log/nginx

# Test configuration
/usr/sbin/nginx -t
\`\`\`

## Running Tengine

### Foreground (for testing)

\`\`\`bash
./start-tengine.sh
\`\`\`

### As a daemon

\`\`\`bash
/usr/sbin/nginx
\`\`\`

### With systemd

\`\`\`bash
# Copy service file
sudo cp tengine.service /etc/systemd/system/

# Enable and start
sudo systemctl daemon-reload
sudo systemctl enable tengine
sudo systemctl start tengine

# Check status
sudo systemctl status tengine
\`\`\`

## Managing Tengine

\`\`\`bash
# Test configuration
/usr/sbin/nginx -t

# Start
/usr/sbin/nginx

# Stop gracefully
/usr/sbin/nginx -s quit

# Stop immediately
/usr/sbin/nginx -s stop

# Reload configuration
/usr/sbin/nginx -s reload

# Reopen log files
/usr/sbin/nginx -s reopen
\`\`\`

## Uninstallation

\`\`\`bash
sudo ./uninstall.sh
\`\`\`

## Directory Structure

\`\`\`
/opt/tengine/          - Tengine home directory
  ├── lualib/          - Lua libraries
  ├── luamod/          - Lua C modules
  ├── luajit/          - LuaJIT installation
  ├── Tongsuo/         - GMSSL/Tongsuo
  ├── pcre2/           - PCRE2 library
  ├── zlib/            - zlib library
  ├── geoip/           - GeoIP library
  └── brotli/          - Brotli library

/etc/nginx/            - Configuration files
  ├── nginx.conf       - Main configuration
  ├── conf.d/          - Virtual host configs
  └── ssl/             - SSL certificates

/usr/sbin/nginx        - Tengine binary
/var/lib/nginx/        - Temporary files
/var/log/nginx/        - Log files
\`\`\`

## Features

- **Tengine modules**: All built-in Tengine modules enabled
- **Lua support**: LuaJIT with lua-nginx-module
- **GMSSL**: National cryptographic standards via Tongsuo
- **Compression**: Brotli and gzip
- **GeoIP2**: IP geolocation support
- **HTTP/2**: Full HTTP/2 support
- **PCRE2 JIT**: Optimized regex performance

## Portable Usage

You can copy this entire directory to another compatible Linux machine:

\`\`\`bash
# Package it
tar czf tengine-portable.tar.gz tengine-portable/

# Transfer to another machine
scp tengine-portable.tar.gz user@remote:/tmp/

# On remote machine
tar xzf /tmp/tengine-portable.tar.gz
cd tengine-portable
sudo ./install.sh
\`\`\`

## Troubleshooting

### "error while loading shared libraries"

This usually means a runtime dependency is missing. Install the required packages:

\`\`\`bash
# RHEL/Rocky/Fedora
sudo dnf install -y gd libxslt libxml2 libmaxminddb

# Ubuntu/Debian
sudo apt-get install -y libgd3 libxslt1.1 libxml2 libmaxminddb0
\`\`\`

### Check what libraries are needed

\`\`\`bash
ldd /usr/sbin/nginx
\`\`\`

All libraries under \`/opt/tengine/\` should show up, only system libraries should be external.

### Permission denied

Make sure:
- nginx binary is executable: \`chmod +x /usr/sbin/nginx\`
- nginx user exists and has proper permissions
- Log and temp directories are writable by nginx user

## Support

For issues and questions, please visit:
- Tengine: https://tengine.taobao.org/
- Repository: https://github.com/ikunkfc/docker-tengine

## License

Tengine is licensed under the 2-clause BSD license.
EOF

# Create package info file
cat > "$OUTPUT_DIR/package-info.txt" << EOF
Tengine Portable Package Information
=====================================

Build Information:
------------------
Version: $NGINX_VERSION
Build Date: $TIMESTAMP
Architecture: x86_64
Base OS: RockyLinux 9
Builder: Docker multi-stage build

Package Contents:
-----------------
- Tengine binary: usr/sbin/nginx
- Tengine home: opt/tengine/
- Configuration: etc/nginx/
- Installation script: install.sh
- Uninstall script: uninstall.sh
- Systemd service: tengine.service
- Startup script: start-tengine.sh
- Documentation: README.md

Bundled Libraries (via RPATH):
-------------------------------
- LuaJIT ${LUAJIT_VERSION:-unknown}
- Tongsuo ${TONGSUO_VERSION:-unknown}
- PCRE2 ${PCRE2_VERSION:-unknown}
- zlib ${ZLIB_VERSION:-unknown}
- Brotli ${BROTLI_VERSION:-unknown}
- GeoIP ${GEOIP_VERSION:-unknown}

System Dependencies Required:
------------------------------
- glibc 2.34+
- libgd
- libxslt
- libxml2
- libmaxminddb

Notes:
------
- All custom-compiled libraries use RPATH for self-contained operation
- Only minimal system libraries are required on target machine
- Package can be transferred between compatible Linux systems
- See README.md for detailed installation instructions
EOF

# Create archive
echo "Creating archive..."
ARCHIVE_NAME="tengine-rockylinux9-x86_64-${TIMESTAMP}.tar.gz"
tar czf "$ARCHIVE_NAME" -C "$OUTPUT_DIR" .

# Calculate checksums
echo "Calculating checksums..."
sha256sum "$ARCHIVE_NAME" > "${ARCHIVE_NAME}.sha256"

# Final summary
echo ""
echo "==================================================="
echo "Package created successfully!"
echo "==================================================="
echo ""
echo "Package directory: $OUTPUT_DIR"
echo "Archive: $ARCHIVE_NAME"
echo "Checksum: ${ARCHIVE_NAME}.sha256"
echo ""
echo "Package size:"
du -sh "$OUTPUT_DIR"
echo ""
echo "Archive size:"
ls -lh "$ARCHIVE_NAME" | awk '{print $5}'
echo ""
echo "To install on a target machine:"
echo "  1. Extract: tar xzf $ARCHIVE_NAME"
echo "  2. Run: cd tengine-portable && sudo ./install.sh"
echo ""
echo "To verify the package:"
echo "  sha256sum -c ${ARCHIVE_NAME}.sha256"
echo ""
