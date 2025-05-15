#!/bin/bash

. build_utils.sh

test_match() {
  local f=$1
  local p=$(codeowners_pattern_to_regex "$2")
  if [[ $f =~ $p ]]; then return 0; fi
  return 1
}

# absolute matching
test_match "/foo/bar" "/foo" || exit 1
test_match "/a/foo" "/foo" && exit 1
test_match "/foo/bar" "foo/bar" || exit 1
test_match "/a/foo/bar" "foo/bar" && exit 1
# relative matching
test_match "/bar" "bar" || exit 1
test_match "/foo/bar" "bar" || exit 1
test_match "/foobar" "bar" && exit 1
test_match "/foo/bar" "ba" && exit 1
test_match "/foo/bar" "ar" && exit 1
# directory-only matching
test_match "/foo" "/foo/" && exit 1
test_match "/foo/" "/foo/" && exit 1
test_match "/foo/bar" "/foo/" || exit 1
# asterisk
test_match "/x" "/*" || exit 1
test_match "/xy" "/*" || exit 1
test_match "/Ax" "/A*" || exit 1
test_match "/Axy" "/A*" || exit 1
test_match "/Bx" "/A*" && exit 1
test_match "/xA" "/*A" || exit 1
test_match "/xyA" "/*A" || exit 1
test_match "/xB" "/*A" && exit 1
test_match "/AxyzB" "/A*B" || exit 1
test_match "/A/B" "/A*B" && exit 1
test_match "/AB" "/A*B" || exit 1
test_match "/AxB" "/A*B" || exit 1
test_match "/AxyzB" "/A*B" || exit 1
test_match "/A/B" "/A*B" && exit 1
test_match "/x.y" "/*.*" || exit 1
test_match "/x." "/*.*" || exit 1
test_match "/.y" "/*.*" || exit 1
# question
test_match "/AxB" "A?B" || exit 1
test_match "/AB" "A?B" && exit 1
test_match "/AxxB" "A?B" && exit 1
test_match "/A/B" "A?B" && exit 1
# double-asterisk
test_match "/foo" "**/foo" || exit 1
test_match "/x/foo" "**/foo" || exit 1
test_match "/x/y/foo" "**/foo" || exit 1
test_match "/foo/bar" "**/foo/bar" || exit 1
test_match "/x/y/foo/bar" "**/foo/bar" || exit 1
test_match "/x/y/bar" "**/foo/bar" && exit 1
test_match "/abc/" "abc/**" || exit 1
test_match "/abc/x" "abc/**" || exit 1
test_match "/abc/x/y" "abc/**" || exit 1
test_match "/foo/abc/" "abc/**" && exit 1
test_match "/a/b" "a/**/b" || exit 1
test_match "/a/x/b" "a/**/b" || exit 1
test_match "/a/x/y/b" "a/**/b" || exit 1
test_match "/foo/a/x/y/b" "a/**/b" && exit 1

echo "all tests passed"
