#! /usr/bin/env bash

set -e

echo "Enter project name"
read PROJECT
echo "Enter github name as in github.com/ceph/<github_name>"
read GITHUB

echo "You entered:"
echo "PROJECT=$PROJECT"
echo "GITHUB=$GITHUB"

if test -e ${PROJECT}; then
	echo "The current directory already contains ${PROJECT} directory, please remove it first."
	exit 1
fi

## Create the initial directory structure
cp -a template ${PROJECT}

## Fix up the filenames
mv ${PROJECT}/config/definitions/template.yml ${PROJECT}/config/definitions/${PROJECT}.yml

find ${PROJECT} -type f -exec sed -i -e "s/PROJECT/$PROJECT/g" {} \;
find ${PROJECT} -type f -exec sed -i -e "s/GITHUB/$GITHUB/g" {} \;

echo "The following jobs was created:" ${PROJECT}
echo "Please follow all the TODO markers to complete the creation of the build job."
exit 0
