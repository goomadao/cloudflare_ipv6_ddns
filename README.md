# cloudflare_ipv6_ddns
Modify the value of auth email, key, name of zone, names of records and mac addresses and run it periodically.
- Auth key can be found in cloudflare account settings.
- A mac address can have several domains (for reverse proxy or other functions).

## usage
### for a single device
Make sure that the mac_addr array must be ("00:00:00:00:00:00").
### for a openwrt router and has a IPv6 prefix delivered by the ISP
The mac_addr array can have several values and 00:00:00:00:00:00 stands for the router itself.
