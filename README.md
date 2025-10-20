A simple Bash script for checking SSL/TLS certificate expiration dates. If remaining validity period is less than the specified the threshold the script send am email alert by sendmail.
You can easily integrate this script tointorontab to automate daily monitoring!

Dependencies:
- configured sendmail/postfix
