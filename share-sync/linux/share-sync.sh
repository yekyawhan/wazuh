#!/bin/bash

# ===============================================
# Wazuh Share Sync Linux
# One Shot Sync
# systemd timer runs every 1 minute
# ===============================================


SOURCE="/var/ossec/etc/shared"

DESTINATION="/var/ossec/active-response/bin"

LOGFILE="/var/ossec/logs/share-sync.log"


EXTENSIONS=(
    "*.sh"
    "*.py"
    "*.bin"
)



write_log()
{
    local MESSAGE="$1"

    local TIME

    TIME=$(date "+%Y-%m-%d %H:%M:%S")

    echo "$TIME $MESSAGE" >> "$LOGFILE"
}



# Ensure destination exists

mkdir -p "$DESTINATION"



for EXT in "${EXTENSIONS[@]}"
do

    find "$SOURCE" -maxdepth 1 -type f -name "$EXT" 2>/dev/null | while read FILE
    do

        FILENAME=$(basename "$FILE")

        DEST_FILE="$DESTINATION/$FILENAME"


        COPY=false



        if [ ! -f "$DEST_FILE" ]
        then

            COPY=true

        else


            SRC_HASH=$(sha256sum "$FILE" | awk '{print $1}')

            DST_HASH=$(sha256sum "$DEST_FILE" | awk '{print $1}')


            if [ "$SRC_HASH" != "$DST_HASH" ]
            then

                COPY=true

            fi

        fi



        if [ "$COPY" = true ]
        then

            if install -m 0750 -o root -g wazuh "$FILE" "$DEST_FILE"
            then

                write_log "SYNC : $FILENAME"

            else

                write_log "ERROR : $FILENAME"

            fi

        fi


    done

done
