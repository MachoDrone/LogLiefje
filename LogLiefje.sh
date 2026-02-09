#!/bin/bash
echo "v0.00.4b"   # increment number for each edit
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

hqsap_i_url=$'\x68\x74\x74\x70\x73\x3a\x2f\x2f\x73\x6c\x61\x63\x6b\x2e\x63\x6f\x6d\x2f\x61\x70\x69\x2f\x63\x68\x61\x74\x2e\x70\x6f\x73\x74\x4d\x65\x73\x73\x61\x67\x65'

# ------------- UPLOAD TO LITTERBOX (temporary view link) -------------
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

# ------------- UPLOAD TO SLACK AS PERMANENT ATTACHMENT -------------
echo "Uploading file to Slack as permanent attachment..."
INITIAL_COMMENT="<@${USER_ID}> New log uploaded:  <${UPLOAD_URL}|View Log> <-Download Now! link expires in 72 hours>"

SLACK_RESPONSE=$(curl -s -F file=@"$TEXT_FILE" \
  -F channels="$CHANNEL_ID" \
  -F filename="$(basename "$TEXT_FILE")" \
  -F title="Log file - $(date '+%Y-%m-%d %H:%M:%S')" \
  -F initial_comment="$INITIAL_COMMENT" \
  -H "Authorization: Bearer $mana" \
  https://slack.com/api/files.upload )

if echo "$SLACK_RESPONSE" | grep -q '"ok":true'; then
    echo "✅ File uploaded to Slack as attachment (permanent, no expiration)"
else
    echo "❌ Slack file upload failed"
    echo "$SLACK_RESPONSE"
fi
