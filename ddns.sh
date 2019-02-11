#!/bin/bash

# CHANGE THESE
auth_email="user@example.com"
auth_key="xxxxxxxxxx" # found in cloudflare account settings
zone_name="example.com"
record_name=("1.example.com" "2.example.com") #An array of record name to update, the amount and order must be the same with the mac_addr
mac_addr=("00:00:00:00:00:00" "xx:xx:xx:xx:xx:xx") #00:00:00:00:00:00 stands for the router

# MAYBE CHANGE THESE
prefix_file="/tmp/cloudflare_ipv6_ddns/prefix.txt"
id_file="/tmp/cloudflare_ipv6_ddns/cloudflare.ids"
ip_file="/tmp/cloudflare_ipv6_ddns/ip.txt"
log_file="/tmp/cloudflare_ipv6_ddns/cloudflare.log"

# LOGGER
log() {
    if [ "$1" ]; then
        echo -e "[$(date)] - $1" >> $log_file
    fi
}

# SCRIPT START


[ ! -d "/tmp/cloudflare_ipv6_ddns" ] && mkdir /tmp/cloudflare_ipv6_ddns


BasePath=$(cd `dirname ${BASH_SOURCE}` ; pwd)
BaseName=$(basename $BASH_SOURCE)
ShellPath="$BasePath/$BaseName"

if [ ! -z "$(ps | grep \"$ShellPath\" | grep -v grep)" ]
then
    kill -9 "$(ps | grep \"$ShellPath\" | grep -v grep | xargs)"
    rm -rf $prefix_file $id_file $ip_file $log_file
fi


# check whether the prefix has changed
echo "Getting prefix..."
while true
do
    prefix=$(ubus call network.interface.lan status | grep '"address": "2' | grep -o '[a-f0-9:]*' | tail -1)
    if [ -z "$prefix" ]
    then
        log "Prefix can't be empty."
        echo -e "Prefix can't be empty."
        sleep 3
        continue
    else
        break
    fi
done

if [ -f $prefix_file ]; then
    old_prefix=$(cat $prefix_file)
    if [ $prefix == $old_prefix ]; then
        echo "Prefix has not changed."
        log "Prefix has not changed."
        # exit 0
    else
        log "Prefix changed to: $prefix"
        echo "Prefix changed to: $prefix"
    fi
else
    log "DDNS service starts. Initial prefix: $prefix"
fi



#make sure to get the zone_id
echo "Getting zone id..."

if [ -f $id_file ] && [ $(wc -l $id_file | cut -d " " -f 1) == 2 ]; then
    zone_identifier=$(head -1 $id_file)
else
    zone_identifier_message=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones?name=$zone_name" -H "X-Auth-Email: $auth_email" -H "X-Auth-Key: $auth_key" -H "Content-Type: application/json")
    # echo "zone_identifier_message:$zone_identifier_message
    # "
    if [[ "$zone_identifier_message" == *"result\":\[\]"* ]]
    then
        log "No such zone, please check the name of your zone.\n$zone_identifier_message"
        echo -e "No such zone, please check the name of your zone."
        exit 1
    elif [[ "$zone_identifier_message" == *"\"success\":false"* ]]
    then
        log "The auth email and key may be wrong, please check again.\n$zone_identifier_message"
        echo -e "the auth email and key may be wrong, please check again."
        exit 1
    elif [[ "$zone_identifier_message" != *"\"success\":true"* ]]
    then
        log "Get zone id for $zone_name failed."
        echo -e "Get zone id for $zone_name failed."
        exit 1
    fi
    zone_identifier=$(echo $zone_identifier_message | grep -o '[a-z0-9]*' | head -3 | tail -1)
    echo "$zone_identifier" > $id_file
    echo "$prefix" > $prefix_file
fi


for ((i=0;i<${#record_name[@]};++i))
do
    unset ip
    echo "Changing IP for record: ${record_name[i]}..."
    if [ "${mac_addr[i]}" = "00:00:00:00:00:00" ]
    then
        ip=$(ifconfig | grep Global | grep '[a-f0-9:]*' -o | grep '^2' | grep ':' | xargs) #$(ifconfig | grep $prefix | grep -o '[a-z0-9:]*' | head -3 | tail -1)
    else
        prefix_fd92=$(ip neigh show | grep "${mac_addr[i]}" | cut -d " " -f 1 | grep "^fd92")
        for ((j=1;j<=$(echo "$prefix_fd92" | wc -w);++j))
        do
            ip="${ip} ${prefix%?}$(echo $prefix_fd92 | cut -d " " -f $j | cut -d ":" -f 5-8)"
        done
        ipv6_addr=$(ip neigh show | grep "${mac_addr[i]}" | cut -d " " -f 1 | grep -v '\.' | grep -v '^f' | grep "${prefix%?}")
        for ((j=1;j<=$(echo $ipv6_addr | wc -w);++j))
        do
            comp=$(echo ${ip[@]} | grep "$(echo $ipv6_addr | cut -d " " -f $j)")
            if [[ "$comp" == "" ]]
            then
                ip="${ip} $(echo $ipv6_addr | cut -d " " -f $j)"
            fi
        done
        ip=$(echo ${ip[@]} | sed 's/ /\n/g' | sort | xargs)

        # ip="${prefix%?}$(ip neigh show | grep ${mac_addr[i]} | grep ^fe80 | cut -d ":" -f 5-8 | cut -d " " -f 1)" #$(ip nei show | grep ${mac_addr[i]} | grep ${prefix%?} | head -1 | cut -d " " -f 1)
    fi

    if [ "$ip" = "" ]
    then
        flag=1
        log "Empty ip address for the ${i}th(st,nd) device, please check the mac address:${mac_addr[i]}"
        echo -e "Empty ip address for the ${i}th(st,nd) device, please check the mac address:${mac_addr[i]}"
        continue
    fi


    

    if [ ! -f $ip_file ]
    then
        echo "${mac_addr[i]}=$ip" > $ip_file
    else
        if [ -z "$(cat $ip_file | grep "^${mac_addr[i]}")" ]
        then
            echo "${mac_addr[i]}=$ip" >> $ip_file
        else
            # 获取旧的IP
            old_ip=$(cat $ip_file | grep "${mac_addr[i]}" | cut -d "=" -f 2)

            if [[ "$old_ip" == "$ip" ]]
            then
                echo "IP for ${mac_addr[i]} has not changed."
                log "IP for ${mac_addr[i]} has not changed."
                continue
            else
                sed -i "/^${mac_addr[i]}/c${mac_addr[i]}=$ip" $ip_file
            fi
        fi
    fi

    while true
    do
        deleting_record_id_message=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$zone_identifier/dns_records?name=${record_name[i]}" \
            -H "X-Auth-Email: $auth_email" \
            -H "X-Auth-Key: $auth_key" \
            -H "Content-Type: application/json")
        if [[ "$deleting_record_id_message" != *"success\":true"* ]]
        then
            log "Getting deleting record's id for ${record_name[i]} failed, retrying..."
            echo -e "Getting deleting record's id for ${record_name[i]} failed, retrying..."
            continue
        else
            break
        fi
    done

    #delete old records
    echo "Deleting records for ${record_name[i]}..."
    deleting_record_id=$(echo $deleting_record_id_message | grep -o '[a-z0-9]*","type' | cut -d '"' -f 1 | xargs)
    if [ ! -z "$deleting_record_id" ]
    then
        deleting_record_id=($deleting_record_id)
        for ((j=0;j<${#deleting_record_id[@]};++j))
        do
            while true
            do
                deleting_message=$(curl -s -X DELETE "https://api.cloudflare.com/client/v4/zones/$zone_identifier/dns_records/${deleting_record_id[j]}" \
                    -H "X-Auth-Email: $auth_email" \
                    -H "X-Auth-Key: $auth_key" \
                    -H "Content-Type: application/json")
                if [[ "$deleting_message" != *"success\":true"* ]]
                then
                    log "Deleting record ${deleting_record_id[j]} for ${record_name[i]} failed, retrying..."
                    echo -e "Deleting record ${deleting_record_id[j]} for ${record_name[i]} failed, retrying..."
                    continue
                else
                    break
                fi
            done
        done
    fi

    #create new record
    echo "Creating records for ${record_name[i]}..."
    ip=($ip)
    for ((j=0;j<${#ip[@]};++j))
    do
        while true
        do
            create_message=$(curl -s -X POST "https://api.cloudflare.com/client/v4/zones/${zone_identifier}/dns_records" \
                -H "X-Auth-Email: $auth_email" \
                -H "X-Auth-Key: $auth_key" \
                -H "Content-Type: application/json" \
                --data "{\"type\":\"AAAA\",\"name\":\"${record_name[i]}\",\"content\":\"${ip[j]}\",\"ttl\":120,\"proxied\":false}")
            if [[ "$create_message" != *"success\":true"* ]]
            then
                log "Creating record ${record_name[i]} for IP ${ip[j]} failed, retrying..."
                echo -e "Creating record ${record_name[i]} for IP ${ip[j]} failed, retrying..."
                continue
            else
                break
            fi
        done
    done
done

exit 0