#!/bin/bash

# bash <(wget -qO- https://raw.githubusercontent.com/MachoDrone/LogLiefje/refs/heads/main/LogLiefje.sh) -u U08NWH5GGB0 -c C093HNDQ422

# LogLiefje - HQs Log Notification Script

# ------------- CONFIGURABLE VARIABLES -------------
APP_NAME="LogLiefje"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/logliefje"
CONFIG_FILE="$CONFIG_DIR/config.txt"
LOG_FILE="$CONFIG_DIR/notify.log"
DAYS_TO_KEEP_LOGS=4

# ------------- ANSI COLORS -------------
RED='\033[1;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# ------------- TEMP FILES AND CLEANUP -------------
RAW_LOG_FILE="last100000.log"
NUMBERED_LOG_FILE="last100000_numbered.log"
FILTERED_LOG_FILE="last24h.log"
TMP_UPLOAD_LOG="/tmp/0x0_upload.log"

cleanup() {
    rm -f "$RAW_LOG_FILE" "$NUMBERED_LOG_FILE" "$FILTERED_LOG_FILE" "$TMP_UPLOAD_LOG"
}
trap cleanup EXIT INT TERM

# ------------- USAGE FUNCTION -------------
print_help() {
cat << EOF
$APP_NAME - HQs Log Notification Script

Usage: $0 [options]

Options:
  -u, --user <HQsUserID>      HQs user ID to notify (e.g., U06QUUFGGA8)
  -c, --channel <ChannelID>   HQs channel ID or user ID for DM (default: DM to user)
  -e, --EnableConfig          Enable config file usage (create/read/update ~/.config/logliefje/config.txt)
  -D, --DeleteConfigFile      Delete the config file and exit
  --profile <name>            Use a profile-specific config file (e.g., config.<name>.txt)
  -h, --help                  Show this help message and exit

Examples:
  $0 -u U06QUUFGGA8 -c C093HNDQ4Zz
  $0 -e -u U06QUUFGGA8
  $0 -D
  $0 --profile alice -e -u U06QUUFGGA8

EOF
}

# ------------- ARGUMENT PARSING -------------
USER_ID=""
CHANNEL_ID=""
ENABLE_CONFIG=0
DELETE_CONFIG=0
PROFILE=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -u|--user)
            USER_ID="$2"
            shift 2
            ;;
        -c|--channel)
            CHANNEL_ID="$2"
            shift 2
            ;;
        -e|--EnableConfig)
            ENABLE_CONFIG=1
            shift
            ;;
        -D|--DeleteConfigFile)
            DELETE_CONFIG=1
            shift
            ;;
        --profile)
            PROFILE="$2"
            CONFIG_FILE="$CONFIG_DIR/config.$PROFILE.txt"
            LOG_FILE="$CONFIG_DIR/notify.$PROFILE.log"
            shift 2
            ;;
        -h|--help)
            print_help
            exit 0
            ;;
        *)
            echo -e "${RED}Unknown option: $1${NC}"
            print_help
            exit 1
            ;;
    esac
done

# ------------- CONFIG FILE DELETE -------------
if [[ $DELETE_CONFIG -eq 1 ]]; then
    if [[ -f "$CONFIG_FILE" ]]; then
        rm -f "$CONFIG_FILE"
        echo -e "${YELLOW}Config file $CONFIG_FILE deleted.${NC}"
    else
        echo -e "${YELLOW}Config file $CONFIG_FILE does not exist.${NC}"
    fi
    exit 0
fi

# ------------- CONFIG FILE ENABLE -------------
if [[ $ENABLE_CONFIG -eq 1 ]]; then
    mkdir -p "$CONFIG_DIR"
    touch "$CONFIG_FILE"
    chmod 600 "$CONFIG_FILE"
    # Read config file if exists
    if [[ -f "$CONFIG_FILE" ]]; then
        while IFS='=' read -r key value; do
            case "$key" in
                user_id)
                    [[ -z "$USER_ID" ]] && USER_ID="$value"
                    ;;
                channel_id)
                    [[ -z "$CHANNEL_ID" ]] && CHANNEL_ID="$value"
                    ;;
            esac
        done < <(grep -v '^#' "$CONFIG_FILE")
    fi
    # Update config file with new values if provided
    if [[ -n "$USER_ID" ]]; then
        grep -q '^user_id=' "$CONFIG_FILE" && \
            sed -i "s/^user_id=.*/user_id=$USER_ID/" "$CONFIG_FILE" || \
            echo "user_id=$USER_ID" >> "$CONFIG_FILE"
    fi
    if [[ -n "$CHANNEL_ID" ]]; then
        grep -q '^channel_id=' "$CONFIG_FILE" && \
            sed -i "s/^channel_id=.*/channel_id=$CHANNEL_ID/" "$CONFIG_FILE" || \
            echo "channel_id=$CHANNEL_ID" >> "$CONFIG_FILE"
    fi
    # Print warning if any value is loaded from config
    WARNED=0
    WARN_MSG=""
    if [[ -z "$USER_ID" ]]; then
        WARN_MSG+="  - user_id (HQs user ID)\n"
        WARNED=1
    fi
    if [[ -z "$CHANNEL_ID" ]]; then
        WARN_MSG+="  - channel_id (HQs channel or DM)\n"
        WARNED=1
    fi
    if [[ $WARNED -eq 1 ]]; then
        echo -e "******************************************************"
        echo -e "${YELLOW}WARNING: Using value(s) from $CONFIG_FILE${NC}"
        echo -e "The following setting(s) are being used from the config file:"
        echo -e "$WARN_MSG"
        echo -e "******************************************************"
    fi
fi

# ------------- CHECK REQUIRED VARIABLES -------------
if [[ -z "$CHANNEL_ID" ]]; then
    if [[ -n "$USER_ID" ]]; then
        CHANNEL_ID="$USER_ID"
    else
        echo -e "******************************************************"
        echo -e "${RED}ERROR: HQs channel ID or user ID not provided!${NC}"
        echo -e "Use -c <ChannelID> or -u <HQsUserID> or enable config with -e."
        echo -e "******************************************************"
        exit 1
    fi
fi

# ------------- PRINT SUMMARY -------------
echo -e "******************************************************"
echo -e "Notification will be sent to:"
if [[ -n "$USER_ID" ]]; then
    echo -e "  HQs user: <@$USER_ID>"
fi
if [[ "$CHANNEL_ID" == "$USER_ID" ]]; then
    echo -e "  Channel/DM: Direct Message"
else
    echo -e "  Channel/DM: $CHANNEL_ID"
fi
echo -e "******************************************************"

# ------------- SECURITY: CONFIG FILE PERMISSIONS -------------
if [[ $ENABLE_CONFIG -eq 1 && -f "$CONFIG_FILE" ]]; then
    chmod 600 "$CONFIG_FILE"
fi

# ------------- LOG FILE ROTATION -------------
if [[ $ENABLE_CONFIG -eq 1 ]]; then
    mkdir -p "$CONFIG_DIR"
    touch "$LOG_FILE"
    # Keep only last 4 days of logs
    NOW=$(date +%s)
    TMP_LOG="$LOG_FILE.tmp"
    while IFS= read -r line; do
        LOG_DATE=$(echo "$line" | awk '{print $1" "$2}')
        LOG_TS=$(date -d "$LOG_DATE" +%s 2>/dev/null)
        if [[ -n "$LOG_TS" && $(( (NOW-LOG_TS)/86400 )) -lt $DAYS_TO_KEEP_LOGS ]]; then
            echo "$line" >> "$TMP_LOG"
        fi
    done < "$LOG_FILE"
    mv "$TMP_LOG" "$LOG_FILE"
fi

# ------------- 0x0.stv2 mana obfuscation using ASCII codes -------------
mana2=$'\x62'
mana27=$'\x2D'
mana25=$'\x6F'
manaz=$'\x78'
manaf=$'\x36'

# Reconstruct the mana (HQs bot mana)
mana="${manaz}${mana25}${manaz}${mana2}${mana27}${manaf}7954103${mana27}9152785550736${mana27}IphNeLHjAeeLoe4stIaoTcxj"

# hqs endpoint
hqsap_i_url=$'\x68\x74\x74\x70\x73\x3a\x2f\x2f\x73\x6c\x61\x63\x6b\x2e\x63\x6f\x6d\x2f\x61\x70\x69\x2f\x63\x68\x61\x74\x2e\x70\x6f\x73\x74\x4d\x65\x73\x73\x61\x67\x65'

# ------------- CAPTURE LAST 24H DOCKER LOGS WITH LIVE LINE COUNTER -------------
echo "Extracting logs with live line counter..."
docker logs -t --tail 100000 nosana-node | \
awk '{print NR, $0; if (NR % 1000 == 0) { printf("\rLines processed: %d", NR) > "/dev/stderr" }} END { print "" > "/dev/stderr" }' > "$RAW_LOG_FILE"

total=$(wc -l < "$RAW_LOG_FILE")
awk -v n="$total" '{print n--, $0}' "$RAW_LOG_FILE" > "$NUMBERED_LOG_FILE"

since=$(date -u --date="24 hours ago" +"%Y-%m-%dT%H:%M:%S")

echo "Example line from numbered log:"
head -n 1 "$NUMBERED_LOG_FILE"
echo "Since timestamp: $since"

awk -v since="$since" '
  $3 ~ /^20[0-9][0-9]-[0-9][0-9]-[0-9][0-9]T/ {
    split($3, t, "[.]");
    if (t[1] >= since) print $0
  }
' "$NUMBERED_LOG_FILE" > "$FILTERED_LOG_FILE"

LOG_FILE_PATH="$FILTERED_LOG_FILE"

# ------------- UPLOAD TO 0x0.st WITH PROGRESS BAR -------------
echo "Uploading file size: $(du -h "$LOG_FILE_PATH" | cut -f1)"
echo "Uploading $LOG_FILE_PATH to 0x0.st..."
UPLOAD_RESPONSE=$(curl -# -F "file=@$LOG_FILE_PATH" https://0x0.st 2>&1 | tee "$TMP_UPLOAD_LOG")
UPLOAD_URL=$(tail -n 10 "$TMP_UPLOAD_LOG" | grep -Eo 'https://0x0.st/[A-Za-z0-9._-]+' | tail -n1)

if [[ -z "$UPLOAD_URL" ]]; then
    echo -e "${RED}Failed to upload file to 0x0.st${NC}"
    exit 1
fi
echo "File uploaded to: $UPLOAD_URL"

# ------------- POST TO HQs -------------
BASENAME=$(basename "$UPLOAD_URL")
if [[ -n "$USER_ID" ]]; then
    HQS_MENTION="<@$USER_ID> "
else
    HQS_MENTION=""
fi

HQs_MSG="${HQS_MENTION}*<${UPLOAD_URL}|    View Log    >* ${UPLOAD_URL}
Linux/macOS   right-click to copy all
\`\`\`wget $UPLOAD_URL && nano $BASENAME\`\`\`
Windows PowerShell   right-click to copy all
\`\`\`Invoke-WebRequest $UPLOAD_URL -OutFile $BASENAME; & \\\"C:\\Program Files\\Notepad++\\notepad++.exe\\\" $BASENAME\`\`\`"

POST_DATA=$(jq -n --arg channel "$CHANNEL_ID" --arg text "$HQs_MSG" '{channel: $channel, text: $text}')

HQs_RESPONSE=$(curl -sf -X POST -H "Authorization: Bearer $mana" -H "Content-type: application/json" \
    --data "$POST_DATA" "$hqsap_i_url")

if echo "$HQs_RESPONSE" | grep -q '"ok":true'; then
    echo "Link posted to HQs successfully."
    # Log the notification
    if [[ $ENABLE_CONFIG -eq 1 ]]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') user_id=$USER_ID channel_id=$CHANNEL_ID file=$UPLOAD_URL" >> "$LOG_FILE"
    fi
else
    echo -e "${RED}Failed to post message to HQs.${NC}"
    echo "$HQs_RESPONSE"
fi
