alias gcc='gcc -W -Wall'
alias g++='g++ -W -Wall'

csb() {
    rm cscope.{files,out}
    find $(pwd) -name '*.c' -o -name '*.h' -o -name '*.cpp' -o -name '*.hpp' > cscope.files
    #cscope -i cscope.files -b
    cscope -b
}

alias e='emacsclient -t -a emacs'
