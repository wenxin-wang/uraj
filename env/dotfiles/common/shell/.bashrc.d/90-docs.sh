alias panlatex="pandoc --template=$HOME/snippets/tex/pandoc.tex --latex-engine=xelatex -t latex"

mkd2latex() {
    panlatex -f markdown -o ${1%.*}.pdf $@
}

mkd2html() {
    pandoc -s -f markdown -t html --latexmathml -o ${1%.*}.html $@
}

mkd2reveal() {
    pandoc --template=$HOME/snippets/pandoc-templates/default.revealjs -t revealjs -o ${1%.*}.html $@
}

panrst2html() {
    if [[ $# -ne 1 ]]; then
        echo "need input name"
        return 1
    fi
    pandoc -s -f rst -t html -o ${1%.*}.html $1
}
