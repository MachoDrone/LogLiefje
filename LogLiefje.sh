#!/bin/bash
echo "v0.00.8"   # increment number for each edit
sleep 3          # so the version can be seen quickly during tests

# ================================================
# Upload to Litterbox + Notify Slack Template
# ================================================

# ------------- CONFIG (EDIT THESE) -------------
CHANNEL_ID="C093HNDQ422"          # Target Slack channel
USER_ID="U08NWH5GG8O"             # User to mention
EXPIRATION="72h"                  # Expiration time (72h max)

# ================================================
# === YOUR CODE GOES HERE ========================
# Create / prepare your .txt file in this section
# ================================================

# ←←← PUT YOUR CODE HERE ←←←
# Examples:
#   echo "Log content..." > mylog.txt
#   cp lastNhours.log mylog.txt
#   cat somefile.log > mylog.txt
#   ... your own commands ...

TEXT_FILE="mylog.txt"   # ← MUST be a .txt file (important for browser viewing)

# ================================================
# === DO NOT EDIT BELOW THIS LINE ================
# ================================================

# ------------- MANA OBFUSCATION (do not change) -------------
mana2=$'\x62'
mana27=$'\x2D'
mana25=$'\x6F'
manaz=$'\x78'
manaf=$'\x36'

mana="${manaz}${mana25}${manaz}${mana2}${mana27}${manaf}7954103${mana27}9152785550736${mana27}IphNeLHjAeeLoe4stIaoTcxj"

# ------------- UPLOAD TO LITTERBOX -------------
echo "Uploading to Litterbox (${EXPIRATION})..."
UPLOAD_URL=$(curl -s -F "reqtype=fileupload" \
                   -F "time=$EXPIRATION" \
                   -F "fileToUpload=@$TEXT_FILE" \
                   https://litterbox.catbox.moe/resources/internals/api.php)

echo "$UPLOAD_URL"

if [[ -z "$UPLOAD_URL" || ! "$UPLOAD_URL" =~ ^https://litter.catbox.moe/ ]]; then
    echo "Upload failed!"
    exit 1
fi

# ------------- UPLOAD TO SLACK (new permanent method) -------------
echo "Uploading to Slack (permanent attachment)..."

# Step 1: Get upload URL
LENGTH=$(stat -c%s "$TEXT_FILE" 2>/dev/null || stat -f%z "$TEXT_FILE" 2>/dev/null)
GET_RESPONSE=$(curl -s -X POST \
  -H "Authorization: Bearer $mana" \
  -H "Content-type: application/json" \
  --data "{\"filename\":\"$(basename "$TEXT_FILE")\",\"length\":$LENGTH}" \
  https://slack.com/api/files.getUploadURLExternal)

UPLOAD_URL_SLACK=$(echo "$GET_RESPONSE" | jq -r '.upload_url')
FILE_ID=$(echo "$GET_RESPONSE" | jq -r '.file_id')

if [[ "$UPLOAD_URL_SLACK" == "null" || -z "$UPLOAD_URL_SLACK" ]]; then
    echo "Failed to get Slack upload URL"
    echo "$GET_RESPONSE"
    exit 1
fi

# Step 2: Upload the file
curl -s -T "$TEXT_FILE" "$UPLOAD_URL_SLACK" > /dev/null

# Step 3: Complete the upload
INITIAL_COMMENT="<@${USER_ID}> New log uploaded:  <${UPLOAD_URL}|View Log> <-Download Now! link expires in 72 hours>"

COMPLETE_RESPONSE=$(curl -s -X POST \
  -H "Authorization: Bearer $mana" \
  -H "Content-type: application/json" \
  --data "{\"files\":[{\"id\":\"$FILE_ID\"}],\"channel_id\":\"$CHANNEL_ID\",\"initial_comment\":\"$INITIAL_COMMENT\"}" \
  https://slack.com/api/files.completeUploadExternal)

if echo "$COMPLETE_RESPONSE" | grep -q '"ok":true'; then
    echo "✅ Permanent file uploaded to Slack!"
else
    echo "❌ Slack upload failed"
    echo "$COMPLETE_RESPONSE"
fi
