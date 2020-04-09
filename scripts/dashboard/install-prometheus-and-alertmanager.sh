#!/bin/bash

set -ex

# Install and run Prometheus
# Use $WORKSPACE dir since it will be wiped after the job has completed
cd $WORKSPACE
sudo mkdir prometheus
cd prometheus
sudo curl -LO https://github.com/prometheus/prometheus/releases/download/v2.15.2/prometheus-2.15.2.linux-amd64.tar.gz
sudo tar xf prometheus-2.15.2.linux-amd64.tar.gz
cd prometheus-2.15.2.linux-amd64

sudo ./prometheus &

cd $WORKDIR

# Install and run Alertmanager
sudo mkdir alertmanager
cd alertmanager
sudo curl -LO https://github.com/prometheus/alertmanager/releases/download/v0.20.0/alertmanager-0.20.0.linux-amd64.tar.gz
sudo tar xf alertmanager-0.20.0.linux-amd64.tar.gz
cd alertmanager-0.20.0.linux-amd64

sudo ./alertmanager &

# "pkill prometheus" and "pkill alertmanager" must be executed in the Jenkins job that uses this script
