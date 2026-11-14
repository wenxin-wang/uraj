# fwd2home 全隧道吞掉 redroid 网段

hypie's fwd2home is a full tunnel (strongSwan's `from all lookup 220`), which
captured the bridge subnet in both directions: ADB from the host timed out
and Android's DNS failed.  hypie therefore sets `vpn-bypass-priority` to
200, so the restricted-network service adds `to 10.203.0.0/24 lookup main`
ahead of it; startup checks that the subnet routes through `br-redroid`.  Reconfiguration does not restart the
running service; apply such changes with `sudo herd restart restricted-network`, then start the dependent redroid instance again.
