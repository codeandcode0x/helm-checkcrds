# Helm Checkcrd
Checkcrd in Helm to check k8s crd whether if it's working.

## Support resource
- pod ( deployment, statefulset, controller pod )
- configmap
- service
- job
- secret
- pv / pvc
- crd ( nedd binding clusterRole ServiceAccount )

## Install

```
➜ helm plugin install https://github.com/codeandcode0x/helm-checkcrds
Installed plugin: checkcrd
```

## Usage

```
➜ helm checkcrd [OPTIONS]
Options:
  --crd      crd type (pod,configmap,crd,pv,pvc,secret)
  --name     crd name

```

## Example
- cli
```sh
➜ helm checkcrd --crd pod --name app=mysql
➜ helm checkcrd --crd configmap --name nginx-config
➜ helm checkcrd --crd secret --name db-token
...
```

- shell script
infra.sh
```sh
#!/usr/bin/env sh
helm upgrade --install mariadb
helm upgrade --install nginx
```
app.sh
```sh
#!/usr/bin/env sh
helm checkcrd --crd pod --name app=mariadb
helm checkcrd --crd pod --name app=nginx
helm upgrade --install myapp
```
run.sh
```sh
./infra.sh &
./app.sh &
```

# Maintainer
- roancsu@163.com
- codeandcode0x@gmail.com