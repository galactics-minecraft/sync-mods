#!/bin/bash

# Define variables
MC_VERSION="1.21.1"
FABRIC_INSTALLER_URL="https://maven.fabricmc.net/net/fabricmc/fabric-installer/1.0.1/fabric-installer-1.0.1.jar"
SYNC_SCRIPT_URL="https://raw.githubusercontent.com/galactics-minecraft/sync-mods/main/sync-server-mods.sh"

# Check dependencies
if ! command -v wget &> /dev/null || ! command -v java &> /dev/null || ! command -v curl &> /dev/null; then
    echo "Error: 'wget', 'curl', and 'java' are required to run this script. Please install them."
    exit 1
fi

echo "==> Downloading Fabric Installer..."
wget -q -O fabric-installer.jar "$FABRIC_INSTALLER_URL"

echo "==> Installing Fabric Server for Minecraft $MC_VERSION..."
java -jar fabric-installer.jar server -mcversion "$MC_VERSION" -downloadMinecraft

echo "==> Accepting EULA..."
echo "eula=true" > eula.txt

echo "==> Downloading and Syncing Mods..."
wget -q -O sync-server-mods.sh "$SYNC_SCRIPT_URL"
chmod +x ./sync-server-mods.sh
./sync-server-mods.sh

echo "==> Creating optimized startup script..."
cat << 'EOF' > start.sh
#!/bin/bash
cd "$(dirname "$0")" || exit 1

# commons-compress isn't shipped with the dedicated server jar, but Ultimine Addition needs it.
# It has to be on the JVM classpath, so we launch FabricServerLauncher with -cp instead of -jar.
LIBS="libs/commons-compress-1.26.0.jar"

if [ ! -f "$LIBS" ]; then
  mkdir -p libs
  curl -fL -o "$LIBS" \
    https://repo1.maven.org/maven2/org/apache/commons/commons-compress/1.26.0/commons-compress-1.26.0.jar \
    || { echo "Could not download commons-compress"; exit 1; }
fi

exec java -Xms2G -Xmx4G -XX:+UseG1GC -XX:MaxGCPauseMillis=100 -XX:+UnlockExperimentalVMOptions -XX:+AlwaysPreTouch -XX:G1NewSizePercent=20 -XX:G1MaxNewSizePercent=30 -XX:G1HeapRegionSize=16M -XX:InitiatingHeapOccupancyPercent=15 -XX:+PerfDisableSharedMem -XX:+DisableExplicitGC -XX:+UseStringDeduplication -XX:+ParallelRefProcEnabled \
  -Dlog4j.configurationFile=log4j2.xml \
  -cp "fabric-server-launch.jar:$LIBS" \
  net.fabricmc.loader.impl.launch.server.FabricServerLauncher nogui
EOF

# Make the start script executable
chmod +x start.sh

echo "==> Done! Your mods and server files are in: $(pwd)"
echo "==> To start the server, just run:"
echo "    ./start.sh"
