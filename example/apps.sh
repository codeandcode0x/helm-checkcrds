#!/bin/sh
# add check crd 
helm checkcrd --crd pod --name app.kubernetes.io/name=mariadb
# install apps
helm repo add bitnami https://charts.bitnami.com/bitnami
helm install my-wordpress bitnami/wordpress --version 12.0.3