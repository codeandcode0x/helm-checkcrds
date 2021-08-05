# Helm Checkcrd
Checkcrd in Helm to check k8s crd whether it's working.

## Usage

```
➜ helm checkcrd [OPTIONS]
Options:
  -c  --crd      crd type (pod,configmap,crd,pv,pvc,secret)
  -n, --name     crd name
```

## Install

```
➜ helm plugin install https://github.com/codeandcode0x/helm-checkcrds
Installed plugin: checkcrd
```

# support resource
- pod ( deployment, statefulset, controller pod )
- configmap
- service
- job
- secret
- pv / pvc
- crd ( nedd binding clusterRole ServiceAccount )

# Maintainer
- roancsu@163.com
- codeandcode0x@gmail.com