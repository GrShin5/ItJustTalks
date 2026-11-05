#!/bin/bash
# Output language follows ITJUSTTALKS_LANG (ja/en) or the locale.
UI_LANG="ja"
request="$(printf '%s' "${ITJUSTTALKS_LANG:-}" | tr '[:upper:]' '[:lower:]')"
case "$request" in
  en|en[-_.]*) UI_LANG="en" ;;
  ja|ja[-_.]*) UI_LANG="ja" ;;
  "")
    locale_request="$(printf '%s' "${LC_ALL:-${LC_MESSAGES:-${LANG:-}}}" | tr '[:upper:]' '[:lower:]')"
    case "$locale_request" in ""|ja*|c|c.*|posix) UI_LANG="ja" ;; *) UI_LANG="en" ;; esac ;;
esac
t() { [[ "$UI_LANG" == en ]] && printf '%s' "$2" || printf '%s' "$1"; }
