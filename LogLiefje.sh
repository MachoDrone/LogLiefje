#!/bin/bash
echo v0.00.1 #increment number for each edit
sleep 3 #so the version can be seen quickly during tests
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

hqsap_i_url=$'\x68\x74\x74\x70\x73\x3a\x2f\x2f\x73\x6c\x61\x63\x6b\x2e\x63\x6f\x6d\x2f\x61\x70\x69\x2f\x63\x68\x61\x74\x2e\x70\x6f\x73\x74\x4d\x65\x73\x73\x61\x67\x65'

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

# ------------- SEND TO SLACK (Improved layout) -------------
MESSAGE="New log uploaded:

• <${UPLOAD_URL}|View Log>     <${UPLOAD_URL}|Download log>"

TEXT="<@${USER_ID}> ${MESSAGE}"

POST_DATA=$(jq -n --arg channel "$CHANNEL_ID" --arg text "$TEXT" \
    '{channel: $channel, text: $text}')

RESPONSE=$(curl -s -X POST \
    -H "Authorization: Bearer $mana" \
    -H "Content-type: application/json" \
    --data "$POST_DATA" "$hqsap_i_url")

if echo "$RESPONSE" | grep -q '"ok":true'; then
    echo "✅ Successfully posted to Slack!"
else
    echo "❌ Slack post failed"
    echo "$RESPONSE"
fi
