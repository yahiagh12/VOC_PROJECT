#!/bin/bash
POD=$(kubectl get pods -n voc-core -l app=thehive -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n voc-core "$POD" -- /opt/thehive/entrypoint --help
