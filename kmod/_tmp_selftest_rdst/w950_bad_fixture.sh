# w950_bad_fixture.sh — 故意保留第 61 发 w940 v1 的坏形状，给 w950 扫当正对照
O=/tmp/x.out
one() {
  echo "  A ls=[$(/bin/ls 2>&1)]" >> $O 2>&1
}
{
  echo "M1_A:"
  one
  echo "MZ_END"
} > $O 2>&1
