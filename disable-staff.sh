#!/bin/bash

# Default world folder name is usually "world"
WORLD_DIR=${1:-"world"}
DATAPACK_NAME="disable-sonorous-staff"
MOD_ID="deeperdarker"
ITEM_ID="sonorous_staff"

if [ ! -d "$WORLD_DIR" ]; then
    echo "[FAIL] World directory '$WORLD_DIR' not found."
    echo "Make sure you run this script in your server root AFTER the world has been generated,"
    echo "or pass your custom world folder name: ./disable-staff.sh <world_name>"
    exit 1
fi

DATAPACK_DIR="$WORLD_DIR/datapacks/$DATAPACK_NAME"
RECIPE_DIR="$DATAPACK_DIR/data/$MOD_ID/recipe"

echo "==> Creating datapack structure in $WORLD_DIR/datapacks..."
mkdir -p "$RECIPE_DIR"

echo "==> Writing pack.mcmeta for Minecraft 1.21.1..."
cat << 'EOF' > "$DATAPACK_DIR/pack.mcmeta"
{
  "pack": {
    "pack_format": 48,
    "description": "Disables the Deeper and Darker Sonorous Staff"
  }
}
EOF

echo "==> Writing impossible recipe for $MOD_ID:$ITEM_ID..."
cat << EOF > "$RECIPE_DIR/$ITEM_ID.json"
{
  "type": "minecraft:crafting_shapeless",
  "ingredients": [
    {
      "item": "minecraft:bedrock"
    }
  ],
  "result": {
    "id": "minecraft:dirt",
    "count": 1
  }
}
EOF

echo "==> Done! The datapack '$DATAPACK_NAME' has been applied."
echo "==> If your server is currently running, type 'reload' in the server console to apply changes."
