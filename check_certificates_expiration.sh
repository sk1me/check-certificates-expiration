#!/bin/bash

# Configuration
MONITORED_DOMAINS="./domains.txt"
EMAIL_RECIPIENT="example@gmail.com"
EXPIRY_THRESHOLD=2  # Days remaining to trigger a WARNING alert
EXPIRY_CRITICAL=1    # Days remaining to trigger a CRITICAL alert

# Log file for the script's output
LOG_FILE="/var/log/ssl_check.log"
SENDMAIL="/usr/sbin/sendmail"

# Function to get certificate expiration date in seconds since epoch
get_expiry_epoch() {
    local domain=$1
    local expiry_epoch=""

    # 1. Use 'echo' to send a newline to the session to close it cleanly.
    # 2. Use -showcerts to ensure the full chain is dumped.
    # 3. Suppress all output to STDERR (2>/dev/null) to clean up terminal.
    #    We are specifically NOT redirecting STDOUT here so we can see the full output for debugging.

    # Execute the core OpenSSL chain. We capture the output of the final 'date' conversion.
    expiry_epoch=$( \
        echo | openssl s_client -servername "$domain" -connect "$domain":443 -showcerts 2>/dev/null | \
        
        # Filter: Use sed to print only the first certificate block (the leaf cert).
        # This starts printing at 'BEGIN' and quits immediately after 'END'.
        sed -n '/-----BEGIN CERTIFICATE-----/,$p; /-----END CERTIFICATE-----/q' | \
        
        # Pipe to the second openssl to extract the end date. 
        # Crucially, we redirect this specific command's stderr to /dev/null to hide the 'unable to load certificate' error from the terminal
        openssl x509 -noout -enddate 2>/dev/null | \
        cut -d'=' -f2 | \
        xargs -I {} date -d {} +%s 2>/dev/null \
    )
    
    echo "$expiry_epoch"
}

# --- Main Script Execution ---

CURRENT_EPOCH=$(date +%s)
WARN_SECONDS=$((EXPIRY_THRESHOLD * 24 * 60 * 60))
CRITICAL_SECONDS=$((EXPIRY_CRITICAL * 24 * 60 * 60))

# Email content buffer
EMAIL_BODY="To: $EMAIL_RECIPIENT\nFrom: SSL-Monitor <root@$(hostname)>\nMIME-Version: 1.0\nContent-Type: text/plain; charset=\"UTF-8\"\n\nSSL Certificate Expiration Report\n================================\n\n"

ALERT_FOUND=0
ALERT_STATUS="OK"
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

# Print to terminal and log
echo "--- Starting SSL Check at $TIMESTAMP ---" | tee -a "$LOG_FILE"

if [ ! -f "$MONITORED_DOMAINS" ]; then
    echo "ERROR: Domains file not found at $MONITORED_DOMAINS" | tee -a "$LOG_FILE"
    (echo "To: $EMAIL_RECIPIENT"; echo "Subject: [SSL ALERT - CRITICAL] Config Error"; echo "Domains file not found.") | "$SENDMAIL" -t
    exit 1
fi

while IFS= read -r DOMAIN || [[ -n "$DOMAIN" ]]; do
    DOMAIN=$(echo "$DOMAIN" | tr -d '[:space:]')
    if [[ -z "$DOMAIN" ]]; then continue; fi

    EXPIRY_EPOCH=$(get_expiry_epoch "$DOMAIN")

    if [[ -z "$EXPIRY_EPOCH" || "$EXPIRY_EPOCH" == "0" ]]; then
        STATUS="ERROR"
        MESSAGE="Could not retrieve certificate. **RAW DEBUG:** Check the output above this line for clues."
        ALERT_FOUND=1
        if [ "$ALERT_STATUS" == "OK" ]; then ALERT_STATUS="CRITICAL"; fi
    else
        TIME_DIFF_SECONDS=$((EXPIRY_EPOCH - CURRENT_EPOCH))
        TIME_DIFF_DAYS=$((TIME_DIFF_SECONDS / 86400))
        
        if [ "$TIME_DIFF_SECONDS" -lt 0 ]; then
            STATUS="**EXPIRED**"
            MESSAGE="Certificate is **$TIME_DIFF_DAYS days** expired! Renew Immediately!"
            ALERT_FOUND=1
            ALERT_STATUS="CRITICAL"
        # ... (rest of the logic)
        elif [ "$TIME_DIFF_SECONDS" -le "$CRITICAL_SECONDS" ]; then
            STATUS="CRITICAL"
            MESSAGE="Certificate expires in **$TIME_DIFF_DAYS days**."
            ALERT_FOUND=1
            if [ "$ALERT_STATUS" != "CRITICAL" ]; then ALERT_STATUS="CRITICAL"; fi
        elif [ "$TIME_DIFF_SECONDS" -le "$WARN_SECONDS" ]; then
            STATUS="WARNING"
            MESSAGE="Certificate expires in $TIME_DIFF_DAYS days."
            ALERT_FOUND=1
            if [ "$ALERT_STATUS" == "OK" ]; then ALERT_STATUS="WARNING"; fi
        else
            STATUS="OK"
            MESSAGE="Expires in $TIME_DIFF_DAYS days."
        fi
    fi

    RESULT_LINE="[$STATUS] $DOMAIN: $MESSAGE"
    EMAIL_BODY+="$RESULT_LINE\n"
    # Print result to terminal and log file
    echo "$RESULT_LINE" | tee -a "$LOG_FILE"

done < "$MONITORED_DOMAINS"

echo "--- Finished SSL Check ---" | tee -a "$LOG_FILE"
EMAIL_BODY+="\n================================\nReport Timestamp: $TIMESTAMP"

if [ "$ALERT_FOUND" -eq 1 ]; then
    MAIL_SUBJECT="[SSL ALERT - $ALERT_STATUS] Certificate Expiration Report for RPi Monitor"
    EMAIL_BODY="Subject: $MAIL_SUBJECT\n$EMAIL_BODY"
    echo -e "$EMAIL_BODY" | "$SENDMAIL" -t
fi

exit 0
