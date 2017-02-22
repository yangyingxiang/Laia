#!/bin/bash
export LC_NUMERIC=C;

SDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)";
[ "$(pwd)/steps" = "$SDIR" ] || {
    echo "Run the script from \"$(dirname $SDIR)\"!" >&2 && exit 1;
}
[ ! -f "$(pwd)/utils/parse_options.inc.sh" ] && \
    echo "Missing $(pwd)/utils/parse_options.inc.sh file!" >&2 && exit 1;

exclude_vocab="";
order=10;
overwrite=false;
ptr=lines;
pva=lines;
srilm_options="-wbdiscount -interpolate";
wspace="<space>";
help_message="
Usage: ${0##*/} [options] charmap input_dir output_dir

Options:
  --exclude_vocab : (type = string, default = \"$exclude_vocab\")
                    Exclude the words in this file from the training data
                    (file contains one word per line).
  --order         : (type = int, default = $order)
                    Maximum order of N-grams to count.
  --overwrite     : (type = int, default = $overwrite)
                    Overwrite existing files from previous runs.
  --ptr           : (type = string, default = \"$ptr\")
                    Specify which partition of IAM training data is used.
                    Valid values = forms, lines, sentences.
  --pva           : (type = string, default = \"$pva\")
                    Specify which partition of IAM validation data is used.
                    Valid values = forms, lines, sentences.
  --srilm_options : (type = string, default = \"$srilm_options\")
                    Use SRILM's ngram-count with these options.
  --wspace        : (type = string, default \"$wspace\")
                    Use this symbol to represent the whitespace character.
";
. utils/parse_options.inc.sh || exit 1;
[ $# -ne 3 ] && echo "$help_message" >&2 && exit 1;

cmap="$1";
idir="$2";
odir="$3";

# Check required files.
for f in "$cmap" \
  "$idir/iam/$ptr/tr_normalized.txt" \
  "$idir/iam/$pva/va_normalized.txt" \
  "$idir/iam/$pva/te_normalized.txt" \
  "$idir/brown_normalized.txt" \
  "$idir/lob_excludealltestsets_normalized.txt" \
  "$idir/wellington_normalized.txt"; do
  [ ! -s "$f" ] && echo "File \"$f\" was not found!" >&2 && exit 1;
done;

mkdir -p "$odir/iam/$ptr";

# If no --exclude_vocab option was given, just create /dev/null, as an empty
# file.
[ -z "$exclude_vocab" ] && exclude_vocab="/dev/null";

# Obtain the sequence of characters from the given word vocabulary that must
# be excluded. The file is sorted so that we can filter the text data corpora
# with comm -13, effectively removing the words from the corpora that were
# included in the given vocabulary list.
tmpf="$(mktemp)";
awk -v CMF="$cmap" '
BEGIN{
  while((getline < CMF) > 0) { c=$1; $1=""; gsub(/^\ +/, ""); M[c]=$0; }
}{
  for (i=1;i<=length($0);++i) {
    c = substr($0, i, 1);
    if (c in M) c=M[c];
    printf("%s ", c);
  }
  printf("\n");
}' "$exclude_vocab" |
sed -r 's|^\ +||g;s|\ +$||g;s|\ +| |g' > "$tmpf" ||
exit 1;
exclude_vocab="$tmpf";


function sent2word () {
  sed "s|$wspace|\n|g" $@ | sed -r 's|^\ +||g;s|\ +$||g;s|\ +| |g';
}

function excludevoc () {
  awk -v VF="$exclude_vocab" '
BEGIN{ while((getline < VF) > 0) V[$0]=1; }
!($0 in V){ print; }' $@;
}

vocf="$(mktemp)";
awk '{ $1=""; print }' "$cmap" | tr \  \\n |
awk -v ws="$wspace" 'NF > 0 && $1 != ws' | sort -u > "$vocf";

va_txt="$(mktemp)";
tr_txt="$(mktemp)";
te_txt="$(mktemp)";
cut -d\  -f2- "$idir/iam/$pva/va_normalized.txt" | sent2word | excludevoc > "$va_txt";
cut -d\  -f2- "$idir/iam/$pva/te_normalized.txt" | sent2word | excludevoc > "$te_txt";
cut -d\  -f2- "$idir/iam/$ptr/tr_normalized.txt" | sent2word | excludevoc > "$tr_txt";


# Build n-grams.
for c in brown wellington lob_excludealltestsets; do
  # Create character-level n-gram from the external data.
  lm="$odir/${c}-${order}gram.arpa.gz";
  inf="$odir/${c}-${order}gram.info";
  [[ "$overwrite" = false && -s "$lm" &&
      ( ! "$lm" -ot "$idir/${c}_normalized.txt" ) &&
      ( ! "$lm" -ot "$cmap" ) ]] ||
  ngram-count -order "$order" -vocab "$vocf" $srilm_options \
    -text <(sent2word "$idir/${c}_normalized.txt" | excludevoc) \
    -lm - 2> "$lm.log" |
  gzip -9 -c > "$lm" ||
  ( echo "Error creating file \"$lm\", see \"$lm.log\"!" >&2 && exit 1; );
  # Compute detailed perplexity on the character-level validation set.
  [[ "$overwrite" = false && -s "$inf" &&
      ( ! "$inf" -ot "$lm" ) &&
      ( ! "$inf" -ot "$idir/iam/$pva/va_normalized.txt" ) ]] ||
  ngram -order "$order" -vocab "$vocf" -ppl "$va_txt" -lm <(zcat "$lm") \
    -debug 2 &> "$inf" ||
  ( echo "Error creating file \"$inf\"!" >&2 && exit 1; );
done;


# Create char-level n-gram from the train partition
lm="$odir/iam/$ptr/tr-${order}gram.arpa.gz";
inf="$odir/iam/$ptr/tr-${order}gram.info";
[[ "$overwrite" = false && -s "$lm" &&
    ( ! "$lm" -ot "$idir/iam/$ptr/tr_normalized.txt" ) &&
    ( ! "$lm" -ot "$cmap" ) ]] ||
ngram-count -order "$order" -vocab "$vocf" $srilm_options -text "$tr_txt" \
  -lm -  2> "$lm.log" | gzip -9 -c > "$lm" ||
( echo "Error creating file \"$lm\", see \"$lm.log\"!" >&2 && exit 1; );
# Compute detailed perplexity on the character-level validation set.
[[ "$overwrite" = false && -s "$inf" &&
    ( ! "$inf" -ot "$lm" ) &&
    ( ! "$inf" -ot "$idir/iam/$pva/va_normalized.txt" ) ]] ||
ngram -order "$order" -vocab "$vocf" -ppl "$va_txt" -lm <(zcat "$lm") \
  -debug 2 &> "$inf" ||
( echo "Error creating file \"$inf\"!" >&2 && exit 1; );


# Compute interpolation weights for the character-level n-gram
mix="$odir/interpolation-${order}gram.mix";
[[ "$overwrite" = false && -s "$mix" &&
    ( ! "$mix" -ot "$odir/iam/$ptr/tr-${order}gram.info" ) &&
    ( ! "$mix" -ot "$odir/brown-${order}gram.info" ) &&
    ( ! "$mix" -ot "$odir/lob_excludealltestsets-${order}gram.info" ) &&
    ( ! "$mix" -ot "$odir/wellington-${order}gram.info" ) ]] ||
compute-best-mix \
  "$odir/iam/$ptr/tr-${order}gram.info" \
  "$odir/brown-${order}gram.info" \
  "$odir/lob_excludealltestsets-${order}gram.info" \
  "$odir/wellington-${order}gram.info" &> "$mix" ||
exit 1;


# Interpolate character-level n-grams
lm="$odir/interpolation-${order}gram.arpa.gz";
inf="$odir/interpolation-${order}gram.info";
lambdas=( $(grep "best lambda" "$mix" | awk -F\( '{print $2}' | tr -d \)) );
[[ "$overwrite" = false && -s "$lm" &&
    ( ! "$lm" -ot "$odir/iam/$ptr/tr-${order}gram.arpa.gz" ) &&
    ( ! "$lm" -ot "$odir/brown-${order}gram.arpa.gz" ) &&
    ( ! "$lm" -ot "$odir/lob_excludealltestsets-${order}gram.arpa.gz" ) &&
    ( ! "$lm" -ot "$odir/wellington-${order}gram.arpa.gz" ) ]] ||
ngram -order ${order} -vocab "$vocf" \
  -lm <(zcat "$odir/iam/$ptr/tr-${order}gram.arpa.gz" ) \
  -mix-lm <(zcat "$odir/brown-${order}gram.arpa.gz") \
  -mix-lm2 <(zcat "$odir/lob_excludealltestsets-${order}gram.arpa.gz") \
  -mix-lm3 <(zcat "$odir/wellington-${order}gram.arpa.gz") \
  -lambda ${lambdas[0]} \
  -mix-lambda2 ${lambdas[2]} \
  -mix-lambda3 ${lambdas[3]} \
  -write-lm - 2> "$lm.log" | gzip -9 > "$lm" ||
( echo "Error creating file \"$lm\", see \"$lm.log\"!" >&2 && exit 1; );


# Compute detailed perplexity of the interpolated model
ppl=();
oov=();
tok=();
for f in "$tr_txt" "$va_txt" "$te_txt"; do
  ppl+=( $(ngram -order "$order" -ppl "$f" -lm <(zcat "$lm") 2>&1 |
      tail -n1 | sed -r 's|^.+\bppl= ([0-9.]+)\b.+$|\1|g') );
  aux=( $(awk -v VF="$vocf" '
BEGIN{ N=0; OOV=0; while((getline < VF) > 0) V[$1]=1; }
{ for (i=1;i<=NF;++i) { ++N; if (!($i in V)) ++OOV; } }
END{ print OOV, N; }' "$f") );
  oov+=(${aux[0]});
  tok+=(${aux[1]});
done;


# Print statistics
cat <<EOF >&2
Character-level ${order}-gram:
Train: ppl = ${ppl[0]}, oov = ${oov[0]}, %oov = $(echo "scale=2; 100 * ${oov[0]} / ${tok[0]}" | bc -l)
Valid: ppl = ${ppl[1]}, oov = ${oov[1]}, %oov = $(echo "scale=2; 100 * ${oov[1]} / ${tok[1]}" | bc -l)
Test:  ppl = ${ppl[2]}, oov = ${oov[2]}, %oov = $(echo "scale=2; 100 * ${oov[2]} / ${tok[2]}" | bc -l)
EOF


# Remove temporal files.
rm -f "$tr_txt" "$va_txt" "$te_txt" "$vocf" "$tmpf";

exit 0;