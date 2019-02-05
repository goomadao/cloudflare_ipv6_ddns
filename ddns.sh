#!/bin/bash

# CHANGE THESE
auth_email="user@example.com"
auth_key="xxxxxxxxxx" # found in cloudflare account settings
zone_name="example.com"
record_name=("1.example.com" "2.example.com") #An array of record name to update, the amount and order must be the same with the mac_addr
mac_addr=("00:00:00:00:00:00" "xx:xx:xx:xx:xx:xx") #00:00:00:00:00:00 stands for the router

# MAYBE CHANGE THESE
prefix=$(ubus call network.interface.lan status | grep '"address": "2' | grep -o '[a-f0-9:]*' | tail -1)
prefix_file="/tmp/cloudflare_ipv6_ddns/prefix.txt"
id_file="/tmp/cloudflare_ipv6_ddns/cloudflare.ids"
log_file="/tmp/cloudflare_ipv6_ddns/cloudflare.log"

# LOGGER
log() {
    if [ "$1" ]; then
        echo -e "[$(date)] - $1" >> $log_file
    fi
}

# SCRIPT START


[ ! -d "/tmp/cloudflare_ipv6_ddns" ] && mkdir /tmp/cloudflare_ipv6_ddns


log "Check Initiated"



# check whether the prefix has changed
echo "Getting prefix..."

if [ -f $prefix_file ]; then
    old_prefix=$(cat $prefix_file)
    if [ $prefix == $old_prefix ]; then
        echo "Prefix has not changed."
        exit 0
    fi
fi

log "Prefix changed to: $prefix"
echo "Prefix changed to: $prefix"

#make sure to get the zone_id
echo "Getting zone id..."

if [ -f $id_file ] && [ $(wc -l $id_file | cut -d " " -f 1) == 2 ]; then
    zone_identifier=$(head -1 $id_file)
else
    zone_identifier_message=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones?name=$zone_name" -H "X-Auth-Email: $auth_email" -H "X-Auth-Key: $auth_key" -H "Content-Type: application/json")
    # echo "zone_identifier_message:$zone_identifier_message
    # "
    if [[ $zone_identifier_message == *"result\":\[\]"* ]]
    then
        log "No such zone, please check the name of your zone.\n$zone_identifier_message"
        echo -e "No such zone, please check the name of your zone."
        exit 1
    elif [[ $zone_identifier_message == *"\"success\":false"* ]]
    then
        log "The auth email and key may be wrong, please check again.\n$zone_identifier_message"
        echo -e "the auth email and key may be wrong, please check again."
        exit 1
    elif [[ $zone_identifier_message != *"\"success\":true"* ]]
    then
        log "Get zone id for $zone_name failed."
        echo -e "Get zone id for $zone_name failed."
        exit 1
    fi
    zone_identifier=$(echo $zone_identifier_message | grep -o '[a-z0-9]*' | head -3 | tail -1)
    echo "$zone_identifier" > $id_file
    echo "$prefix" > $prefix_file
fi

flag=0

for ((i=0;i<${#record_name[@]};++i))
do
    echo "Changing IP for record: ${record_name[i]}..."
    if [ ${mac_addr[i]} = "00:00:00:00:00:00" ]
    then
        ip=$(ifconfig | grep $prefix | grep -o '[a-z0-9:]*' | head -3 | tail -1)
    else
        ip="${prefix%?}$(ip neigh show | grep ${mac_addr[i]} | grep ^fe80 | cut -d ":" -f 3-6 | cut -d " " -f 1)" #$(ip nei show | grep ${mac_addr[i]} | grep ${prefix%?} | head -1 | cut -d " " -f 1)
    fi

    if [ $ip = "" ]
    then
        flag=1
        log "Empty ip address for the ${i}th(st,nd) device, please check the mac address:${mac_addr[i]}"
        echo -e "Empty ip address for the ${i}th(st,nd) device, please check the mac address:${mac_addr[i]}"
        continue
    fi

    record_identifier_message=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$zone_identifier/dns_records?name=${record_name[i]}" -H "X-Auth-Email: $auth_email" -H "X-Auth-Key: $auth_key" -H "Content-Type: application/json")
    # echo "record_identifier_message:$record_identifier_message
    # "
    if [[ $record_identifier_message == *"result\":[]"* ]]; then
        message="Record ${record_name[i]} does not exists, will establish it"
        log "$message"
        update=$(curl -s -X POST "https://api.cloudflare.com/client/v4/zones/${zone_identifier}/dns_records" \
            -H "X-Auth-Email: $auth_email" \
            -H "X-Auth-Key: $auth_key" \
            -H "Content-Type: application/json" \
            --data "{\"type\":\"AAAA\",\"name\":\"${record_name[i]}\",\"content\":\"$ip\",\"ttl\":120,\"proxied\":false}")
        if [[ $update != *"success\":true"* ]]
        then
            log "Establish record for ${record_name[i]} failed, retrying..."
            echo -e "Establish record for ${record_name[i]} failed, retrying..."
            i=$i-1
        else
            message="The ip address for the mac address ${mac_addr[i]} has changed to $ip."
            log "$message"
            echo -e "$message"
        fi
    elif [[ $record_identifier_message == *'"result":[{"id":"'* ]]
    then
        record_identifier=$(echo $record_identifier_message | grep -o '[a-z0-9]*' | head -3 | tail -1)
        update=$(curl -s -X PUT "https://api.cloudflare.com/client/v4/zones/$zone_identifier/dns_records/$record_identifier" \
            -H "X-Auth-Email: $auth_email" \
            -H "X-Auth-Key: $auth_key" \
            -H "Content-Type: application/json" \
            --data "{\"id\":\"$zone_identifier\",\"type\":\"AAAA\",\"name\":\"${record_name[i]}\",\"content\":\"$ip\"}")
        if [[ $update != *"success\":true"* ]]
        then
            log "Modify record for ${record_name[i]} failed, retrying..."
            echo -e "Modify record for ${record_name[i]} failed, retrying..."
            i=$i-1
        else
            message="The ip address for the mac address ${mac_addr[i]} has changed to $ip."
            log "$message"
            echo -e "$message"
        fi
    else
        log "Get record id for ${record_name[i]} failed, retrying..."
        echo -e "Get record id for ${record_name[i]} failed, retrying..."
        i=$i-1
    fi

        
    # echo -e "$update"
done

exit $flag