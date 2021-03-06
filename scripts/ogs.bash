#!/bin/bash
# Available variables: $PROJECT, $RUNTYPE, $MIGA, $CORES
set -e
SCRIPT="ogs"
echo "MiGA: $MIGA"
echo "Project: $PROJECT"
# shellcheck source=scripts/miga.bash
source "$MIGA/scripts/miga.bash" || exit 1
cd "$PROJECT/data/10.clades/03.ogs"

# Initialize
miga date > "miga-project.start"

DS=$(miga ls -P "$PROJECT" --ref --no-multi)
MIN_ID=$(miga about -P "$PROJECT" -m ogs_identity)
[[ $MIN_ID == "?" ]] && MIN_ID=80
if [[ ! -s miga-project.ogs ]] ; then
  # Extract RBMs
  if [[ ! -s miga-project.abc ]] ; then
    [[ -d miga-project.tmp ]] || mkdir miga-project.tmp
    for i in $DS ; do
      file="miga-project.tmp/$i.abc"
      [[ -s "$file" ]] && continue
      echo "SELECT seq1,id1,seq2,id2,bitscore from rbm where id >= $MIN_ID;" \
        | sqlite3 "../../09.distances/02.aai/$i.db" | tr "\\|" " " \
        | awk '{ print $1">"$2"'"\\t"'"$3">"$4"'"\\t"'"$5 }' \
        > "$file.tmp"
      mv "$file.tmp" "$file"
    done
    cat miga-project.tmp/*.abc > miga-project.abc
  fi
  rm -rf miga-project.tmp

  # Estimate OGs and Clean RBMs
  ogs.mcl.rb -o miga-project.ogs --abc miga-project.abc -t "$CORES"
  if [[ $(miga about -P "$PROJECT" -m clean_ogs) == "false" ]] ; then
    rm miga-project.abc
  else
    gzip -9 miga-project.abc
  fi
fi

# Calculate Statistics
ogs.stats.rb -o miga-project.ogs -j miga-project.stats
ogs.core-pan.rb -o miga-project.ogs -s miga-project.core-pan.tsv -t "$CORES"
Rscript "$MIGA/utils/core-pan-plot.R" \
  miga-project.core-pan.tsv miga-project.core-pan.pdf

# Finalize
miga date > "miga-project.done"
miga add_result -P "$PROJECT" -r "$SCRIPT" -f
