#!/bin/bash
set -e;

# Directory where the prepare.sh script is placed.
SDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)";
[ "$(pwd)/scripts" != "$SDIR" ] && \
  echo "Please, run this script from the experiment top directory!" && \
  exit 1;

overwrite=false;
height=64;
dataset_name="Spanish_Number_DB";

help_message="
Usage: ${0##*/} [options]

Options:
  --height     : (type = integer, default = $height)
                 Scale lines to have this height, keeping the aspect ratio
                 of the original image.
  --overwrite  : (type = boolean, default = $overwrite)
                 Overwrite previously created files.
";
source "${SDIR}/parse_options.inc.sh" || exit 1;

[ -d data/$dataset_name/adq3/frases2/ -a -s data/$dataset_name/train.lst -a -s data/$dataset_name/test.lst ] || \
  ( echo "The Spanish Number database is not available!">&2 && exit 1; );

mkdir -p data/lang/chars;

echo -n "Creating transcripts..." >&2;
for p in train test; do
  # Place all character-level transcripts into a single txt table file.
  # Token {space} is used to mark whitespaces between words.
  [ -s data/lang/chars/$p.txt -a $overwrite = false ] && continue;
  for s in $(< data/$dataset_name/$p.lst); do
    echo "$s $(cat data/$dataset_name/adq3/frases2/$s.txt | sed 's/./& /g' | sed 's/@/{space}/g')";
  done > data/lang/chars/$p.txt;
done;
echo -e "  \tDone." >&2;

echo -n "Creating symbols table..." >&2;
# Generate symbols table from training and validation characters.
# This table will be used to convert characters to integers using Kaldi format.
[ -s data/lang/chars/symbs.txt -a $overwrite = false ] || (
  for p in train test; do
    cut -f 2- -d\  data/lang/chars/$p.txt | tr \  \\n;
  done | sort -u -V | \
    awk 'BEGIN{N=1;}NF==1{ printf("%-10s %d\n", $1, N); N++; }' \
  > data/lang/chars/symbs.txt;
)
echo -e "  \tDone." >&2;

## Resize to a fixed height and convert to png.
echo -n "Preprocessing images..." >&2;
mkdir -p data/imgs_proc;
for p in train test; do
  # [ -f data/$dataset_name/$p.lst ] && continue;
  for f in $(< data/$dataset_name/$p.lst); do
    [ -f data/imgs_proc/$f.png -a $overwrite = false ] && continue;
    [ ! -f data/$dataset_name/adq3/frases2/$f.pbm ] && \
      echo "Image data/$dataset_name/adq3/frases2/$f.pbm is not available!">&2 \
        && exit 1;
      #echo "File data/$dataset_name/adq3/frases2/$f.pbm..." >&2;
      convert -interpolative-resize "x$height" data/$dataset_name/adq3/frases2/$f.pbm data/imgs_proc/$f.png
  done;
  awk '{ print "data/imgs_proc/"$1".png" }' data/$dataset_name/$p.lst > data/$p.lst;
done;
echo -e "  \tDone." >&2;

exit 0;
