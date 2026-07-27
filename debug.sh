#!/bin/bash

POD=$(kubectl get pods -n voc-core -l app=thehive -o jsonpath='{.items[0].metadata.name}')
echo "Exec into $POD"
kubectl exec -i -n voc-core "$POD" -- sh -c "/opt/thehive/entrypoint --config-file /etc/thehive/application.conf --no-config"
