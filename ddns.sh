#!/bin/bash

# CHANGE THESE
auth_email="user@example.com"
# found in cloudflare account settings
auth_key="xxxxxxxxxx" 
zone_name="example.com"
# An array of record name to update, the amount and order must be the same with the mac_addr, but a device may have several record names(for reverse proxy maybe)
# such as "00:00:00:00:00:00" have 1.example.com, 11.example.com and 111.example.com and "xx:xx:xx:xx:xx:xx" have 2.example.com and 22.example.com
record_name=("1.example.com 11.example.com 111.example.com" "2.example.com 22.example")
#00:00:00:00:00:00 stands for the device itself
mac_addr=("00:00:00:00:00:00" "xx:xx:xx:xx:xx:xx") 

# MAYBE CHANGE THESE
prefix_file="/tmp/cloudflare_ipv6_ddns/prefix.txt"
id_file="/tmp/cloudflare_ipv6_ddns/cloudflare.ids"
ip_file="/tmp/cloudflare_ipv6_ddns/ip.txt"
log_file="/tmp/cloudflare_ipv6_ddns/cloudflare.log"

# LOGGER
log() {
    if [ "$1" ]
    then
        echo -e "[$(date)] - $1" >> $log_file
    fi
}

# get rid of '::' in ipv6 addresses
erase_double_colon() 
{
    if [ -z "$(echo $1 | grep '::')" ]
    then
        echo "$1"
    else
        count=$(echo $1 | sed 's/:/ /g' | wc -w)
        if [ -z "$(echo $1 | grep "^::")" ]
        then
            str_0=" "
        fi
        for ((i=0;i<8-$count;++i))
        do
            str_0="${str_0}0 "
        done
        echo "$(echo $1 | sed 's/:/ /g' | sed "s/  /$str_0/" | sed 's/ /:/g')"
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

# If there is just one mac_addr and it is all 0(stands for the device itself),
# then there is no need to get the prefix.
if [[ ${#mac_addr[@]} != 1 || ${mac_addr[0]} != "00:00:00:00:00:00" ]] 
then
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

    if [ -f $prefix_file ]
    then
        old_prefix=$(cat $prefix_file)
        if [ $prefix == $old_prefix ]
        then
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
fi



#make sure to get the zone_id
echo "Getting zone id..."

if [ -f $id_file ] && [ $(wc -l $id_file | cut -d " " -f 1) == 2 ]
then
    zone_identifier=$(head -1 $id_file)
else
    zone_identifier_message=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones?name=$zone_name" -H "X-Auth-Email: $auth_email" -H "X-Auth-Key: $auth_key" -H "Content-Type: application/json")
    # echo "zone_identifier_message:$zone_identifier_message"
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

# change all devices' domains' IP addresses
for ((i=0;i<${#mac_addr[@]};++i))
do
    # get IP addresses for the mac_address
    unset ip
    echo "Changing IP for device: ${mac_addr[i]}..."
    if [ "${mac_addr[i]}" = "00:00:00:00:00:00" ]
    then
        if type ifconfig > /dev/null 2>&1
        then
            ip=$(ifconfig | grep -i global | grep '[a-f0-9:]*' -o | grep '^2' | grep ':' | xargs)
        else
            if type ip > /dev/null 2>&1
            then
                ip=$(ip address | grep inet6 | grep -i global | sed 's/^ *//g' | cut -d " " -f 2 | cut -d '/' -f 1 | grep ^2 | xargs)
            else
                echo -e "Can't get IP address, please make sure that ip or ifconfig command works on your device."
                log "Can't get IP address, please make sure that ip or ifconfig command works on your device."
                continue;
            fi
        fi
    else
        prefix_fd92=$(ip neigh show | grep "${mac_addr[i]}" | cut -d " " -f 1 | grep "^fd92")
        for ((j=1;j<=$(echo "$prefix_fd92" | wc -w);++j))
        do
            ip="${ip} ${prefix%?}$(echo `erase_double_colon $(echo $prefix_fd92 | cut -d " " -f $j)` | cut -d ":" -f 5-8)"
            # ip="${ip} ${prefix%?}$(echo $prefix_fd92 | cut -d " " -f $j | cut -d ":" -f 5-8)"
        done
        ipv6_addr=$(ip neigh show | grep "${mac_addr[i]}" | cut -d " " -f 1 | grep -v '\.' | grep -v '^f' | grep "${prefix%?}")
        for ((j=1;j<=$(echo $ipv6_addr | wc -w);++j))
        do
            # comp=$(echo ${ip[@]} | grep "$(echo $ipv6_addr | cut -d " " -f $j)")
            cmop=$(echo ${ip[@]} | grep "$(echo `erase_double_colon $(echo $ipv6_addr | cut -d " " -f $j)`)")
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
            # get old IP addresses and compare with the new ones
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

    #change IP into an array
    ip=($ip) 

    record_names=(${record_name[i]})
    for ((ii=0;ii<${#record_names[@]};++ii))
    do
        #get old records' id
        while true
        do
            deleting_record_id_message=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$zone_identifier/dns_records?name=${record_names[ii]}" \
                -H "X-Auth-Email: $auth_email" \
                -H "X-Auth-Key: $auth_key" \
                -H "Content-Type: application/json")
            if [[ "$deleting_record_id_message" != *"success\":true"* ]]
            then
                log "Getting deleting record's id for ${record_names[ii]} failed, retrying..."
                echo -e "Getting deleting record's id for ${record_names[ii]} failed, retrying..."
                continue
            else
                break
            fi
        done

        

        #delete old records
        echo "Deleting records for ${record_names[ii]}..."
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
                        log "Deleting record ${deleting_record_id[j]} for ${record_names[ii]} failed, retrying..."
                        echo -e "Deleting record ${deleting_record_id[j]} for ${record_names[ii]} failed, retrying..."
                        continue
                    else
                        break
                    fi
                done
            done
        fi
        

        #create new record
        echo "Creating records for ${record_names[ii]}..."
        for ((j=0;j<${#ip[@]};++j))
        do
            while true
            do
                create_message=$(curl -s -X POST "https://api.cloudflare.com/client/v4/zones/${zone_identifier}/dns_records" \
                    -H "X-Auth-Email: $auth_email" \
                    -H "X-Auth-Key: $auth_key" \
                    -H "Content-Type: application/json" \
                    --data "{\"type\":\"AAAA\",\"name\":\"${record_names[ii]}\",\"content\":\"${ip[j]}\",\"ttl\":120,\"proxied\":false}")
                if [[ "$create_message" != *"success\":true"* ]]
                then
                    log "Creating record ${record_names[ii]} for IP ${ip[j]} failed, retrying..."
                    echo -e "Creating record ${record_names[ii]} for IP ${ip[j]} failed, retrying..."
                    continue
                else
                    break
                fi
            done
        done
    done
done

exit 0