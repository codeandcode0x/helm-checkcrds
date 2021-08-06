#!/bin/sh
helm repo add nicholaswilde https://nicholaswilde.github.io/helm-charts/
helm repo update
helm install mariadb nicholaswilde/mariadb --version 1.0.5
