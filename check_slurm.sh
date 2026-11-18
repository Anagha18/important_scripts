echo "===== COMPILER ====="
gcc --version | head -n 1

echo "===== BUILD TOOLS ====="
command -v make
command -v debuild
command -v fakeroot

echo "===== LIBBPF ====="
dpkg-query -W libbpf-dev 2>/dev/null

echo "===== DBUS DEVELOPMENT LIBRARY ====="
dpkg-query -W libdbus-1-dev 2>/dev/null

echo "===== SYSTEMD DEVELOPMENT LIBRARY ====="
dpkg-query -W libsystemd-dev 2>/dev/null

echo "===== AVAILABLE DISK SPACE ====="
df -h "$HOME"