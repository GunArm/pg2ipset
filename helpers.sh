#!/bin/bash

find-in-ipsets() {
  local test_ip=$1
  local IFS=$'\n'
  for setname in $(sudo ipset -n list); do 
    sudo ipset test "$setname" "$test_ip" 2>/dev/null && echo "$setname"
  done
}

whitelist-ip() {
  if [ -z "$1" ] || [ -z "$2" ] || [ ! -z "$3" ]; then
    echo "whitelist-ip {ip} {quoted description}"
    return 1
  fi
  local ip=$1
  local desc=$2

  if ! is-ip-valid "$ip"; then
    echo "Invalid IP"
    return 1
  fi

  if [[ "$(find-in-ipsets "$ip")" == *"whitelist"* ]]; then
    echo "$ip is already on whitelist"
    return 1
  fi

  if [[ -z "$(find-in-ipsets "$ip")" ]]; then
    read -p "$ip is NOT currently blocked.  Whitelist anyway? " -n 1 -r; echo;
    if [ "$(echo "$REPLY" | tr '[:upper:]' '[:lower:]')" != "y" ]; then
      return 1
    fi
  fi

  printf "%s #%s\n" "$ip" "$desc" | sudo tee -a /etc/blocklists/whitelist.txt > /dev/null
  echo "Done.  Run ipset-update to apply new items"
}

function is-ip-valid()
{
  local  ip=$1
  local  stat=1

  if [[ $ip =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
    OIFS=$IFS
    IFS='.'
    ip=($ip)
    IFS=$OIFS
    [[ ${ip[0]} -le 255 && ${ip[1]} -le 255 && ${ip[2]} -le 255 && ${ip[3]} -le 255 ]]
    stat=$?
  fi
  return $stat
}
