# some more ls aliases
alias ll='ls -alh'
alias la='ls -Ah'
alias l='ls -CFh'

alias llld='ll -d .*'
alias lld='ls -d .*'

alias u='cd ..'
alias b='cd -'

cl() {
    cd $@ && ls
}

cll() {
    cd $@ && ll
}

mkcl() {
    mkdir $1 && cl $1
}


dtd() {
    if [ $# -eq 0 ]; then
        mkdir -p $(date +%F)
        return
    fi
    local d
    for d in $@; do
        mkdir -p $(date +%F)-"$@"
    done
}

mthd() {
    if [ $# -eq 0 ]; then
        mkdir -p $(date +%Y-%m)
	return
    fi
    local d
    for d in $@; do
        mkdir -p $(date +%Y-%m)-"$d"
    done
}

dtf() {
    if [ $# -eq 0 ]; then
        touch $(date +%Y%m%dT%H%M%S)
	return
    fi
    local f
    for f in $@; do
        touch $(date +%Y%m%dT%H%M%S)--"$f"
    done
}

mthf() {
    if [ $# -eq 0 ]; then
        touch $(date +%Y-%m)
	return
    fi
    local f
    for f in $@; do
        touch $(date +%Y-%m)-"$f"
    done
}

mdtf() {
    local d=$(date +%F)
    local m=${d%-*}
    mkdir -p $m
    if [ $# -eq 0 ]; then
        touch $m/$d
	return
    fi
    local f
    for f in $@; do
        touch $m/$d-"$f"
    done
}

dtmv() {
    local src
    for src in $@; do
        local d=$(stat -c '%w' "$src" | cut -d' ' -f1)
        local dst=$d-"$src"
        mv "$src" "$dst"
    done
}

mdtmv() {
    local src
    for src in $@; do
        local d=$(stat -c '%w' "$src" | cut -d' ' -f1)
        local m=${d%-*}
        local dst=$d-"$src"
        mkdir -p $m
        mv "$src" $m/"$dst"
    done
}
