alias looplay='mplayer -loop 0'

alias mnt='udevil mount $@'
alias umnt='udevil umount $@'

alias newsmth="luit -encoding gbk ssh wwxwwx@newsmth.net"
alias newsmth-expect='expect -c "set timeout 60; spawn luit -encoding gbk ssh newsmth.net; interact timeout 30  {send \"\000\"}; "'
