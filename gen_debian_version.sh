#!/bin/sh

raw=$1
dist=$2

[ "$dist" = "sid" ] && dver="$raw"
[ "$dist" = "jessie" ] && dver="$raw~bpo80+1"
[ "$dist" = "wheezy" ] && dver="$raw~bpo70+1"
[ "$dist" = "squeeze" ] && dver="$raw~bpo60+1"
[ "$dist" = "lenny" ] && dver="$raw~bpo50+1"
[ "$dist" = "xenial" ] && dver="$raw$dist"
[ "$dist" = "trusty" ] && dver="$raw$dist"
[ "$dist" = "saucy" ] && dver="$raw$dist"
[ "$dist" = "raring" ] && dver="$raw$dist"
[ "$dist" = "precise" ] && dver="$raw$dist"
[ "$dist" = "oneiric" ] && dver="$raw$dist"
[ "$dist" = "natty" ] && dver="$raw$dist"
[ "$dist" = "maverick" ] && dver="$raw$dist"
[ "$dist" = "lucid" ] && dver="$raw$dist"
[ "$dist" = "karmic" ] && dver="$raw$dist"

echo $dver

