# storie 切换到 host macvlan

Prepare the router's DHCP reservation for `02:31:00:00:00:02`, then
reconfigure and reboot to switch the network and discard old leases/addresses
on the physical interface. Check the server's DHCP client-ID matching rules
as well as its MAC reservation; the host address is supplied by DHCP.
