O=/tmp/x.out
one() {
  echo "  A ls=[$(/bin/ls 2>&1)]" >> $O 2>&1
}
{
  echo "M1_A:"
  one
  echo "MZ_END"
} > $O 2>&1
